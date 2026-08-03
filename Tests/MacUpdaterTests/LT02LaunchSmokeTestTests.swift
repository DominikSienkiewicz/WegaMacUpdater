import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

/// LT-02 — the launch smoke test: what the observation window is allowed to conclude.
///
/// Before this, the post-upgrade canary was the Gatekeeper verdict plus a Team ID comparison.
/// Both describe the *artifact*; neither describes what happens when it runs, so a build that
/// crashes on startup passed every gate and was announced as a successful update.
///
/// These pin the decision logic in `MacUpdaterCore` against a stand-in probe. The real
/// `NSWorkspace` launch is the untestable half and lives behind `AppLaunchProbing`
/// deliberately; the timing contract is additionally exercised against genuinely
/// asynchronous, real processes in `LT02LaunchSmokeProcessLifetimeTests`.
@Suite("LT-02 — launch smoke test")
struct LT02LaunchSmokeTestTests {

    // MARK: The window

    /// The ordinary healthy upgrade: the instance is alive for the whole window, and the
    /// test cleans up after itself rather than leaving a hidden copy of the app running.
    @Test func aProcessThatOutlivesTheWindowSurvivesAndIsStoppedAfterwards() async {
        let probe = FakeLaunchProbe(script: .staysAlive)

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.2, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
        )

        #expect(verdict == .survived)
        #expect(!LaunchSmokeTest.requiresRollback(verdict))
        #expect(await probe.handle?.wasAskedToTerminate == true,
                "LT-02: the smoke test ends the instance it started — every upgraded app left running hidden would be a worse bug than the one being detected")
    }

    /// The failure the card exists for: a build that dies immediately after launch.
    @Test func aProcessThatDiesImmediatelyExitsEarlyAndDemandsARollback() async {
        let probe = FakeLaunchProbe(script: .exits(afterObservations: 0))

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.2, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
        )

        guard case .exitedEarly = verdict else {
            Issue.record("LT-02: a crash at startup must be seen as an early exit, got \(verdict)")
            return
        }
        #expect(LaunchSmokeTest.requiresRollback(verdict),
                "LT-02: an early exit is what makes the guard restore the snapshot")
    }

    /// A slower crash — a few polls in, still well inside the window.
    ///
    /// The window is deliberately far wider than the scripted crash needs. The probe scripts
    /// the exit by *observation count* while the window closes on the wall clock, so a window
    /// only a few poll intervals wide is a race: on a loaded runner a single `Task.sleep`
    /// overruns, the window closes before the third reading, and a crash that this suite
    /// exists to catch is reported as `.survived`. Widening the window removes the race
    /// without softening the claim — `after` is still required to be a small fraction of the
    /// window, which is exactly what "dated from the launch" means, and is a tighter bound
    /// than the `after < window` this asserted before.
    @Test func aProcessThatDiesPartwayThroughTheWindowExitsEarly() async {
        let window: TimeInterval = 30
        let probe = FakeLaunchProbe(script: .exits(afterObservations: 2))

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: window, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
        )

        guard case .exitedEarly(let after) = verdict else {
            Issue.record("LT-02: a crash inside the window must be seen, got \(verdict)")
            return
        }
        #expect(after < window / 2,
                "LT-02: an early exit is dated from the launch, not from the window's end")
    }

    /// The check must sit **around** the window, not beside it.
    ///
    /// `pollInterval == window` gives the driver exactly one in-window poll, and this
    /// process is alive for it — it dies in the gap between that poll and the moment the
    /// window closes. The only reading that can catch it is the one taken on the closing
    /// edge, and that is precisely the reading a "sleep N seconds, then look" implementation
    /// does not have.
    ///
    /// Red before the fix: delete the closing-edge read at the end of `run` and this returns
    /// `.survived` — a build that crashed inside the window ships as a successful update.
    @Test func aProcessThatDiesInTheLastPollGapIsNotAllowedToPassAsSurvived() async {
        let probe = FakeLaunchProbe(script: .exits(afterObservations: 1))

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.1, pollInterval: 0.1, terminationGrace: 0.2, probe: probe
        )

        guard case .exitedEarly = verdict else {
            Issue.record("LT-02: the closing edge of the window is inside it — got \(verdict)")
            return
        }
    }

    /// Liveness is only ever read through the handle the launch produced, so the proof that
    /// the process started exists before the window opens — and a launch that never produced
    /// one is never observed at all.
    @Test func aLaunchThatNeverHappenedIsNeverObserved() async {
        let refused = FakeLaunchProbe(script: .refuses(.failed("bundle is damaged")))
        _ = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.2, pollInterval: 0.02, terminationGrace: 0.2, probe: refused
        )
        #expect(await refused.handle == nil,
                "LT-02: nothing was started, so there is nothing to watch and nothing to stop")

        let launched = FakeLaunchProbe(script: .staysAlive)
        _ = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.2, pollInterval: 0.02, terminationGrace: 0.2, probe: launched
        )
        #expect((await launched.handle?.observations ?? 0) > 1,
                "LT-02: the window is watched throughout, not merely waited out")
    }

    // MARK: Nothing learned is never a rollback

    /// An app the user already has open is theirs: the smoke test may neither start a second
    /// copy nor terminate the running one, so it stands down — and must not undo the upgrade
    /// on the strength of having learned nothing.
    @Test func anAlreadyRunningAppIsSkippedAndNeverRolledBack() async {
        let probe = FakeLaunchProbe(script: .refuses(.skipped(.alreadyRunning)))

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.2, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
        )

        #expect(verdict == .skipped(.alreadyRunning))
        #expect(!LaunchSmokeTest.requiresRollback(verdict),
                "LT-02: absence of evidence must never be spent as a reason to undo an upgrade")
    }

    @Test func aBundleWithNothingToLaunchIsSkippedAndNeverRolledBack() async {
        let probe = FakeLaunchProbe(script: .refuses(.skipped(.unsupportedBundle)))

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.2, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
        )

        #expect(verdict == .skipped(.unsupportedBundle))
        #expect(!LaunchSmokeTest.requiresRollback(verdict))
    }

    /// REL-12 — a cancelled run stops the instance it started, but a cancellation says
    /// nothing about the new build, so it cannot be read as a failure.
    @Test func cancellationDuringTheWindowIsSkippedNotAFailure() async {
        let probe = FakeLaunchProbe(script: .staysAlive)

        let task = Task {
            await LaunchSmokeTest.run(
                bundleAt: Self.bundle, window: 30, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let verdict = await task.value

        #expect(verdict == .skipped(.cancelled))
        #expect(!LaunchSmokeTest.requiresRollback(verdict))
        #expect(await probe.handle?.wasEnded == true,
                "REL-12: a cancelled smoke test still does not leave its instance behind")
    }

    // MARK: A launch the system refuses

    /// Gatekeeper has already approved this exact bundle by the time the smoke test runs, so
    /// an executable the system then refuses to start describes a damaged artifact — the gate
    /// fails closed, like every other gate in the chain.
    @Test func aRefusedLaunchFailsClosed() async {
        let probe = FakeLaunchProbe(script: .refuses(.failed("bundle is damaged")))

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.2, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
        )

        #expect(verdict == .launchFailed("bundle is damaged"))
        #expect(LaunchSmokeTest.requiresRollback(verdict),
                "LT-02: Gatekeeper passed this bundle already — a refusal to exec it is the bundle's fault")
    }

    // MARK: Stopping the instance

    /// Polite request, short grace, then an unconditional kill — the escalation `ProcessRunner`
    /// already uses for a cancelled child (REL-12). An app that ignores the quit request must
    /// not be able to outlive the test that started it.
    @Test func anInstanceThatIgnoresTheQuitRequestIsForceTerminated() async {
        let probe = FakeLaunchProbe(script: .staysAliveAndIgnoresTermination)

        _ = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.1, pollInterval: 0.02, terminationGrace: 0.1, probe: probe
        )

        #expect(await probe.handle?.wasAskedToTerminate == true)
        #expect(await probe.handle?.wasForceTerminated == true,
                "LT-02: the grace period ends in a kill, not in a shrug")
    }

    // MARK: The switch

    /// The smoke test is on unless it is switched off, and the absent key on a fresh install
    /// must read as on — `bool(forKey:)` alone would silently return `false`.
    @Test func theSmokeTestIsOnUntilItIsTurnedOff() throws {
        let (defaults, teardown) = TestDefaults.isolated("lt02-smoke-gate")
        defer { teardown() }

        #expect(LaunchSmokeTestConfiguration.isEnabled(defaults: defaults),
                "LT-02: an absent key is a fresh install, and the gate is on by default")

        defaults.set(false, forKey: LaunchSmokeTestConfiguration.enabledKey)
        #expect(!LaunchSmokeTestConfiguration.isEnabled(defaults: defaults))

        defaults.set(true, forKey: LaunchSmokeTestConfiguration.enabledKey)
        #expect(LaunchSmokeTestConfiguration.isEnabled(defaults: defaults))
    }

    private static let bundle = URL(fileURLWithPath: "/Applications/Whatever.app")
}

// MARK: - Stand-in probe

/// What the fake instance does with the window it is given.
private enum LaunchScript: Sendable {
    case staysAlive
    case staysAliveAndIgnoresTermination
    /// Alive for the first `afterObservations` readings, gone from the next one on — which
    /// makes *which* readings the driver takes, and when, directly observable.
    case exits(afterObservations: Int)
    case refuses(AppLaunchOutcome)
}

private actor FakeLaunchProbe: AppLaunchProbing {
    private let script: LaunchScript
    private(set) var handle: FakeLaunchedApp?

    init(script: LaunchScript) { self.script = script }

    func launch(bundleAt url: URL) async -> AppLaunchOutcome {
        if case .refuses(let outcome) = script { return outcome }
        let started = FakeLaunchedApp(script: script)
        handle = started
        return .launched(started)
    }
}

private actor FakeLaunchedApp: LaunchedAppHandle {
    nonisolated let processIdentifier: Int32 = 4242

    private let script: LaunchScript
    private(set) var observations = 0
    private(set) var wasAskedToTerminate = false
    private(set) var wasForceTerminated = false

    init(script: LaunchScript) { self.script = script }

    var wasEnded: Bool { wasAskedToTerminate || wasForceTerminated }

    func hasExited() async -> Bool {
        observations += 1
        switch script {
        case .staysAlive:
            return wasAskedToTerminate || wasForceTerminated
        case .staysAliveAndIgnoresTermination:
            return wasForceTerminated
        case .exits(let afterObservations):
            return observations > afterObservations
        case .refuses:
            return true
        }
    }

    func requestTermination() async { wasAskedToTerminate = true }
    func forceTerminate() async { wasForceTerminated = true }
}
