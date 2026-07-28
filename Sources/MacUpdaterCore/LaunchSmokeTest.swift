import Foundation

/// LT-02 — the "does it actually start?" canary, as pure decision logic.
///
/// Until now the post-upgrade canary was the Gatekeeper verdict plus a publisher comparison
/// (`CanaryCheck.passesGatekeeper`, `CaskRollbackGuard.verify`). Both answer *"is this bundle
/// the thing it claims to be"* — neither answers *"does it run"*. A correctly signed build
/// from the right publisher that dies on `main()` — a missing framework, an incompatible
/// architecture, a truncated bundle — passes every existing gate and lands on the user as a
/// working update.
///
/// This is the missing evidence: start the app hidden, watch it for a few seconds, and treat
/// an early exit as a failed upgrade.
///
/// # Why the window is watched, not sampled
///
/// The obvious spelling — launch, wait N seconds, then ask "is something with that name
/// running?" — is a check placed *beside* the window rather than *around* it. It cannot tell
/// "started and survived" from "never started, but another instance happens to be up", and it
/// misses a process that died and was restarted by something else in between.
///
/// So the proof that the process started is the handle returned by ``AppLaunchProbing/launch(bundleAt:)``
/// — it exists **before** the window opens — and liveness is then observed repeatedly while
/// the window is open *and once more on its closing edge*, so a process that dies inside the
/// last poll gap can never be recorded as having survived. The handle answers for the
/// instance this test started, not for a pid or a process name, so a recycled pid cannot
/// stand in for it either.
public enum LaunchSmokeTest {

    /// What the observation window saw.
    public enum Verdict: Equatable, Sendable {
        /// The instance this test started was alive for the whole window.
        case survived
        /// It exited before the window closed. `after` is how long it lasted.
        case exitedEarly(after: TimeInterval)
        /// It could not be started at all. Gatekeeper has already approved the bundle by the
        /// time this runs, so a refusal here describes a broken artifact, not a policy.
        case launchFailed(String)
        /// No evidence either way — see ``SkipReason``.
        case skipped(SkipReason)
    }

    /// Why a smoke test produced no evidence. None of these is a failure: a probe that could
    /// not run says nothing about the new build, and "nothing was learned" must never be
    /// spent as a reason to undo an upgrade.
    public enum SkipReason: Equatable, Sendable {
        /// The user turned the smoke test off in Settings.
        case disabled
        /// An instance was already running before the upgrade. It is the user's, not ours:
        /// we may neither start a second copy nor terminate theirs to make room.
        case alreadyRunning
        /// There is nothing launchable at the path (no bundle, no executable).
        case unsupportedBundle
        /// The update run was cancelled while the window was open (REL-12).
        case cancelled
    }

    /// Whether a verdict obliges the caller to restore the snapshot.
    ///
    /// `.launchFailed` counts as a failure deliberately: the Gatekeeper gate ran first and
    /// approved this exact bundle, so an executable the system then refuses to start is a
    /// damaged artifact. `.skipped` never does — absence of evidence is not evidence.
    public static func requiresRollback(_ verdict: Verdict) -> Bool {
        switch verdict {
        case .survived, .skipped:        return false
        case .exitedEarly, .launchFailed: return true
        }
    }

    /// Starts the app through `probe`, watches it for `window` seconds, and stops the
    /// instance it started before returning.
    ///
    /// The instance is always stopped — a smoke test that left a hidden copy of every
    /// upgraded app running would be a worse problem than the one it detects.
    public static func run(
        bundleAt url: URL,
        window: TimeInterval = LaunchSmokeTestConfiguration.defaultWindow,
        pollInterval: TimeInterval = LaunchSmokeTestConfiguration.defaultPollInterval,
        terminationGrace: TimeInterval = LaunchSmokeTestConfiguration.defaultTerminationGrace,
        probe: any AppLaunchProbing
    ) async -> Verdict {
        let handle: any LaunchedAppHandle
        switch await probe.launch(bundleAt: url) {
        case .skipped(let reason): return .skipped(reason)
        case .failed(let message): return .launchFailed(message)
        case .launched(let started): handle = started
        }

        // The launch has already succeeded here, before the first tick of the window: this
        // is the proof that the process started, and nothing observed later has to carry it.
        let clock = ContinuousClock()
        let openedAt = clock.now
        let closesAt = openedAt.advanced(by: .seconds(window))

        while clock.now < closesAt {
            if await handle.hasExited() {
                return await stopping(handle, grace: terminationGrace, pollInterval: pollInterval,
                                      verdict: .exitedEarly(after: seconds(from: openedAt, on: clock)))
            }
            do {
                try await Task.sleep(for: .seconds(min(pollInterval, window)))
            } catch {
                return await stopping(handle, grace: terminationGrace, pollInterval: pollInterval,
                                      verdict: .skipped(.cancelled))
            }
        }

        // The closing edge belongs to the window too. Without this read, a process that died
        // during the last poll gap would be reported as having survived the full window.
        if await handle.hasExited() {
            return await stopping(handle, grace: terminationGrace, pollInterval: pollInterval,
                                  verdict: .exitedEarly(after: seconds(from: openedAt, on: clock)))
        }
        return await stopping(handle, grace: terminationGrace, pollInterval: pollInterval, verdict: .survived)
    }

    /// Ends the instance and returns `verdict` unchanged — the stop is cleanup, never a
    /// second chance to change the answer.
    ///
    /// Polite request, short grace, then an unconditional kill: the same escalation
    /// `ProcessRunner` uses for a cancelled child (REL-12), so an app that ignores a quit
    /// request cannot outlive the test that started it.
    private static func stopping(
        _ handle: any LaunchedAppHandle,
        grace: TimeInterval,
        pollInterval: TimeInterval,
        verdict: Verdict
    ) async -> Verdict {
        if await handle.hasExited() { return verdict }
        await handle.requestTermination()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(grace))
        while clock.now < deadline {
            if await handle.hasExited() { return verdict }
            do {
                try await Task.sleep(for: .seconds(min(pollInterval, grace)))
            } catch {
                break
            }
        }
        let stillAlive = await !handle.hasExited()
        if stillAlive { await handle.forceTerminate() }
        return verdict
    }

    private static func seconds(from start: ContinuousClock.Instant, on clock: ContinuousClock) -> TimeInterval {
        let elapsed = clock.now - start
        return TimeInterval(elapsed.components.seconds) + TimeInterval(elapsed.components.attoseconds) * 1e-18
    }
}

/// One app instance that a smoke test started, and the two questions it has to answer.
///
/// Deliberately *not* keyed by pid or process name: a handle answers for the instance it was
/// created from, so neither a recycled pid nor a second copy of the same app can be mistaken
/// for the one under test.
public protocol LaunchedAppHandle: Sendable {
    /// Recorded at launch, for the log. Identity comes from the handle, never from this.
    var processIdentifier: Int32 { get }
    /// True once *this* instance has exited, for any reason.
    func hasExited() async -> Bool
    /// Asks the instance to quit, letting it run its normal shutdown.
    func requestTermination() async
    /// Ends it unconditionally, for an instance that ignored the request.
    func forceTerminate() async
}

/// The result of trying to start an app for a smoke test.
public enum AppLaunchOutcome: Sendable {
    case launched(any LaunchedAppHandle)
    case skipped(LaunchSmokeTest.SkipReason)
    case failed(String)
}

/// The system half of the smoke test, behind a protocol so the decision logic above is
/// exercised against a stand-in — no app bundles, no window server, no real five seconds.
public protocol AppLaunchProbing: Sendable {
    /// Starts the app at `url` without bringing it forward, and returns before the
    /// observation window opens.
    func launch(bundleAt url: URL) async -> AppLaunchOutcome
}

/// The tunables of the launch smoke test, and the switch that turns it off.
public enum LaunchSmokeTestConfiguration {
    /// `UserDefaults` key shared by the settings toggle and the rollback guard that reads it.
    public static let enabledKey = "wega.launchSmokeTest.enabled.v1"

    /// The smoke test is on unless the user turns it off. It is the only gate that catches a
    /// crash-at-startup, which is the most common way an update actually fails; the escape
    /// hatch exists for apps that take badly to being started and closed unattended.
    public static let enabledByDefault = true

    /// How long the process has to stay alive. A startup crash — missing framework, wrong
    /// architecture, damaged bundle — happens in the first moments; five seconds is long
    /// enough to see it and short enough that a batch of casks stays bearable.
    public static let defaultWindow: TimeInterval = 5

    /// How often liveness is read while the window is open.
    public static let defaultPollInterval: TimeInterval = 0.25

    /// How long a polite quit request is given before the instance is killed.
    public static let defaultTerminationGrace: TimeInterval = 2

    /// Absent from `UserDefaults` on a fresh install, which must read as *on* — hence the
    /// explicit `object(forKey:)`, since `bool(forKey:)` would silently return `false`.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? enabledByDefault
    }
}
