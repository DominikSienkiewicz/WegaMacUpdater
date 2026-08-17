import Darwin
import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-02 — the smoke test must not tear down an app that is mid-authorization.
///
/// The bug these pin, observed on 2026-08-17 against Docker Desktop 4.87.0: the cask upgrade
/// replaced the bundle, the smoke test launched the new build hidden, and Docker's backend
/// immediately raised a system authorization dialog to reinstate its privileged helper
/// (`configuring vmnetd [set-vmnetd set-docker-socket]`). The smoke test saw a live process for
/// the whole window, ruled `.survived`, and then ran its unconditional teardown — SIGTERM to the
/// app took the `osascript` holding the password dialog with it, 7.4 s after it appeared
/// (`defaultWindow` 5 s + `defaultTerminationGrace` 2 s). Docker's log recorded the death as
/// `process 99307 exited with signal code 15` and an empty `applescript error:`.
///
/// The privileged step therefore never completed, `com.docker.vmnetd` never landed in
/// `/Library/PrivilegedHelperTools/`, and every later launch re-prompted and crashed with
/// `exit status 151`. A teardown that interrupts a system authorization is destructive, not
/// cleanup — so an open prompt has to suspend it.
@Suite("LT-02 — an open authorization prompt suspends the teardown")
struct LT02AuthorizationPromptTests {

    /// The regression. A live instance plus an open authorization prompt must be left alone.
    ///
    /// Red before the fix: `AppLaunchProbing` has no `hasOpenAuthorizationPrompt()` at all, so
    /// the teardown is unconditional and the child is dead by the time the verdict comes back.
    @Test func anInstanceHoldingAnAuthorizationPromptIsNotTerminated() async throws {
        let probe = AuthorizationSubprocessProbe(script: "sleep 30", promptIsOpen: true)

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle,
            window: 0.3,
            pollInterval: 0.05,
            terminationGrace: 0.5,
            probe: probe
        )

        #expect(verdict == .skipped(.awaitingAuthorization),
                "LT-02: an open prompt is 'no evidence', never a survival to be cashed in")
        let handle = try #require(probe.handle)
        #expect(await handle.hasExited() == false,
                "LT-02: killing the app cancels the authorization the user is still answering")
        #expect(handle.wasAskedToStop == false,
                "LT-02: not even a polite quit request — Docker's prompt dies with its app")

        await handle.forceTerminate()
    }

    /// The counterweight: with no prompt open, the teardown stays exactly as it was. Without
    /// this, a fix could silently leave a hidden copy of every upgraded app running.
    @Test func anInstanceWithNoOpenPromptIsStillStopped() async throws {
        let probe = AuthorizationSubprocessProbe(script: "sleep 30", promptIsOpen: false)

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle,
            window: 0.3,
            pollInterval: 0.05,
            terminationGrace: 0.5,
            probe: probe
        )

        #expect(verdict == .survived)
        let handle = try #require(probe.handle)
        #expect(await handle.hasExited(),
                "LT-02: the ordinary path still stops what it started")
    }

    /// The data half of the fix: an app known to perform a privileged repair on its first run
    /// after an upgrade is never smoke-tested in the first place, so the race cannot start.
    @Test func dockerDesktopIsExemptFromTheSmokeTest() {
        #expect(LaunchSmokeTestConfiguration.isExemptFromSmokeTest(token: "docker-desktop"))
        #expect(LaunchSmokeTestConfiguration.isExemptFromSmokeTest(token: "obsidian") == false,
                "LT-02: the exemption is a named list, not a blanket opt-out")
    }

    private static let bundle = URL(fileURLWithPath: "/Applications/Whatever.app")
}

// MARK: - Stand-ins

/// A real child process, so "was it killed?" is answered by the operating system rather than by
/// a flag the test sets itself — the same reason `LT02LaunchSmokeProcessLifetimeTests` spawns
/// `/bin/sh` instead of scripting a handle.
private final class AuthorizationSubprocessProbe: AppLaunchProbing, @unchecked Sendable {
    private(set) var handle: AuthorizationSubprocessHandle?

    private let script: String
    private let promptIsOpen: Bool
    private let lock = NSLock()

    init(script: String, promptIsOpen: Bool) {
        self.script = script
        self.promptIsOpen = promptIsOpen
    }

    func hasOpenAuthorizationPrompt() async -> Bool { promptIsOpen }

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
        let started = AuthorizationSubprocessHandle(process)
        lock.withLock { handle = started }
        return .launched(started)
    }
}

private final class AuthorizationSubprocessHandle: LaunchedAppHandle, @unchecked Sendable {
    let processIdentifier: Int32

    private let process: Process
    private let lock = NSLock()
    private var askedToStop = false

    init(_ process: Process) {
        self.process = process
        self.processIdentifier = process.processIdentifier
    }

    var wasAskedToStop: Bool { lock.withLock { askedToStop } }

    func hasExited() async -> Bool { !process.isRunning }

    func requestTermination() async {
        lock.withLock { askedToStop = true }
        process.terminate()
    }

    func forceTerminate() async {
        lock.withLock { askedToStop = true }
        kill(processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}
