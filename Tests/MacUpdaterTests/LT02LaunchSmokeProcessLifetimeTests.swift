import Darwin
import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-02 — the same driver, against processes that are really running.
///
/// `LT02LaunchSmokeTestTests` scripts the instance so *which* readings the driver takes is
/// directly observable. That is the right way to pin the decision logic, and the wrong way to
/// find out whether the logic still holds when liveness changes on its own schedule rather
/// than on the driver's. These spawn real children through a real `Process`, so the exit is
/// asynchronous, the timing is the operating system's, and the SIGTERM → grace → SIGKILL
/// escalation is delivered for real (the same shape `REL12ProcessLifetimeTests` pins for
/// `ProcessRunner`).
///
/// What still cannot be covered here is the production probe: `WorkspaceAppLaunchProbe`
/// launches an `.app` hidden through `NSWorkspace`, which needs a real GUI session and a real
/// signed bundle. That half is behind `AppLaunchProbing` precisely because it can only be
/// confirmed on a running system.
@Suite("LT-02 — launch smoke test against real processes")
struct LT02LaunchSmokeProcessLifetimeTests {

    /// A child that outlives the window, and is gone once the smoke test returns — the
    /// production shape, where the app under test must not be left running behind the user.
    @Test func aLongLivedChildSurvivesTheWindowAndIsStoppedAfterwards() async throws {
        let probe = SubprocessLaunchProbe(script: "sleep 30")

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.4, pollInterval: 0.05, terminationGrace: 1, probe: probe
        )

        #expect(verdict == .survived)
        let handle = try #require(probe.handle)
        #expect(await handle.hasExited(),
                "LT-02: the smoke test stops the process it started before it returns")
    }

    /// The failure LT-02 exists for, with a real exit status behind it: a child that dies the
    /// moment it starts is what a crash on `main()` looks like from the outside.
    @Test func aChildThatDiesImmediatelyIsReportedAsAnEarlyExit() async {
        let probe = SubprocessLaunchProbe(script: "exit 1")

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 2, pollInterval: 0.05, terminationGrace: 1, probe: probe
        )

        guard case .exitedEarly(let after) = verdict else {
            Issue.record("LT-02: an immediate exit must be seen as an early exit, got \(verdict)")
            return
        }
        #expect(after < 2, "LT-02: the window is abandoned as soon as the process is gone, not waited out")
    }

    /// A slower death, timed by the operating system rather than by a script: still inside
    /// the window, and still a failure.
    @Test func aChildThatDiesPartwayThroughTheWindowIsReportedAsAnEarlyExit() async {
        let probe = SubprocessLaunchProbe(script: "sleep 0.2; exit 3")

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 3, pollInterval: 0.05, terminationGrace: 1, probe: probe
        )

        guard case .exitedEarly(let after) = verdict else {
            Issue.record("LT-02: a delayed crash inside the window must be seen, got \(verdict)")
            return
        }
        #expect(after >= 0.1, "LT-02: the elapsed time is measured from the launch")
        #expect(after < 3)
    }

    /// The escalation, delivered for real. This child installs a `TERM` trap that ignores the
    /// polite request, so it can only be ended by the SIGKILL at the end of the grace period.
    ///
    /// Red before the fix: without the force-terminate step, the smoke test returns while the
    /// child is still running — one stray process per upgraded app.
    @Test func aChildThatIgnoresSigtermIsKilledWhenTheGracePeriodEnds() async throws {
        let probe = SubprocessLaunchProbe(script: "trap '' TERM; sleep 30")

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.3, pollInterval: 0.05, terminationGrace: 0.5, probe: probe
        )

        #expect(verdict == .survived)
        let handle = try #require(probe.handle)
        #expect(handle.wasForceTerminated,
                "LT-02: a process that ignores the quit request is killed, not left behind")
        #expect(await handle.hasExited())
    }

    private static let bundle = URL(fileURLWithPath: "/Applications/Whatever.app")
}

// MARK: - A probe backed by a real child process

/// Stands in for `WorkspaceAppLaunchProbe` with something the test suite can actually run:
/// `/bin/sh` instead of an `.app`. The lifetime — launch, liveness, SIGTERM, SIGKILL — is the
/// real thing, which is the part these tests are about.
private final class SubprocessLaunchProbe: AppLaunchProbing, @unchecked Sendable {
    private(set) var handle: SubprocessHandle?

    private let script: String
    private let lock = NSLock()

    init(script: String) { self.script = script }

    func launch(bundleAt url: URL) async -> AppLaunchOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let started = SubprocessHandle(process)
        lock.withLock { handle = started }
        return .launched(started)
    }
}

private final class SubprocessHandle: LaunchedAppHandle, @unchecked Sendable {
    let processIdentifier: Int32

    private let process: Process
    private let lock = NSLock()
    private var forceTerminated = false

    init(_ process: Process) {
        self.process = process
        self.processIdentifier = process.processIdentifier
    }

    var wasForceTerminated: Bool { lock.withLock { forceTerminated } }

    func hasExited() async -> Bool { !process.isRunning }

    func requestTermination() async { process.terminate() }

    /// `Process` has no SIGKILL of its own, so the signal goes straight to the pid — the
    /// same last resort `ProcessRunner` reaches for when a child ignores SIGTERM (REL-12).
    func forceTerminate() async {
        lock.withLock { forceTerminated = true }
        kill(processIdentifier, SIGKILL)
        // Reaping the child is what flips `isRunning`; without it the caller would keep
        // seeing a zombie as alive.
        //
        // Polled rather than waited on. `waitUntilExit()` blocks the *calling thread*, and
        // under Swift Testing that thread belongs to the concurrency cooperative pool — the
        // same "no bare waitUntilExit" rule `REL12UnboundedProcessGuardTests` enforces on
        // `Sources/`, which this harness was quietly exempt from. With the pool contended,
        // Foundation's own termination bookkeeping cannot get a thread, so `isRunning` never
        // flips and the wait never returns: on 2026-08-18 this hung a `merge.sh` gate for
        // hours on a child that was already dead. `Task.sleep` suspends instead of blocking,
        // which hands the thread back and lets that bookkeeping run.
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
