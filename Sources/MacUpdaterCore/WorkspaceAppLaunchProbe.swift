import AppKit
import Foundation

/// LT-02 — the system half of the launch smoke test: a hidden, non-activating launch through
/// `NSWorkspace`, and the handle that reports on the instance it produced.
///
/// `NSWorkspace.OpenConfiguration` is what makes the test unobtrusive: `activates = false`
/// keeps focus where the user left it and `hides = true` means the app comes up already
/// hidden, so a background round can verify an upgrade without windows appearing on a Mac
/// nobody is sitting at.
///
/// The one case this refuses is an app that is **already running**. `NSWorkspace` would then
/// hand back the user's own instance rather than a new one, and the smoke test ends by
/// terminating what it started — so it would quit an app the user is using. That is reported
/// as `.alreadyRunning`, which never triggers a rollback.
public struct WorkspaceAppLaunchProbe: AppLaunchProbing {
    private let processes: RunningProcessService

    public init(processes: RunningProcessService = RunningProcessService()) {
        self.processes = processes
    }

    /// `SecurityAgent` is the process macOS starts to draw an authorization sheet, and it exists
    /// only while one is on screen — unlike `authd`/`coreauthd`, which run permanently and so
    /// say nothing. Its presence is therefore the available "someone is being asked to
    /// authorize right now" signal, which is what stops the smoke test from killing the app
    /// holding the prompt.
    ///
    /// It answers for the machine, not for this instance: a prompt raised by something else at
    /// the same moment also suspends the teardown. That bias is deliberate — the cost is a
    /// hidden app left running and a `.skipped` verdict, against a cancelled privileged install
    /// the other way.
    public func hasOpenAuthorizationPrompt() async -> Bool {
        await processes.isRunning("SecurityAgent")
    }

    public func launch(bundleAt url: URL) async -> AppLaunchOutcome {
        guard Bundle(url: url)?.executableURL != nil else { return .skipped(.unsupportedBundle) }
        if runningInstance(at: url) != nil { return .skipped(.alreadyRunning) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false

        do {
            let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return .launched(RunningApplicationHandle(application))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func runningInstance(at url: URL) -> NSRunningApplication? {
        let target = url.standardizedFileURL
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == target }
    }
}

/// `NSRunningApplication` refers to one specific launched instance and its properties are
/// documented as safe to read from any thread, which is exactly the guarantee the handle
/// needs — hence `@unchecked Sendable` rather than hopping to the main actor for every poll.
private final class RunningApplicationHandle: LaunchedAppHandle, @unchecked Sendable {
    let processIdentifier: Int32

    private let application: NSRunningApplication

    init(_ application: NSRunningApplication) {
        self.application = application
        self.processIdentifier = application.processIdentifier
    }

    /// Asked of the instance, not of a pid: an app that dies and has its pid handed to
    /// something else still reads as terminated here.
    func hasExited() async -> Bool { application.isTerminated }

    func requestTermination() async { _ = application.terminate() }

    func forceTerminate() async { _ = application.forceTerminate() }
}
