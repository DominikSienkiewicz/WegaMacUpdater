import AppKit
import Foundation
import WegaHelperKit

public protocol ApplicationTerminating: Sendable {
    @MainActor
    func requestTermination(appName: String, processName: String) -> Bool
}

/// Native macOS graceful-quit adapter. `NSRunningApplication.terminate()` asks the
/// application to terminate through AppKit, allowing its normal save/quit handling,
/// without requiring Automation permission for a cross-process AppleScript.
public struct WorkspaceApplicationTerminator: ApplicationTerminating {
    public init() {}

    @MainActor
    public func requestTermination(appName: String, processName: String) -> Bool {
        let application = NSWorkspace.shared.runningApplications.first { application in
            application.localizedName == appName
                || application.executableURL?.lastPathComponent == processName
        }
        return application?.terminate() ?? false
    }
}

/// Detects, asks, terminates, and relaunches running apps via AppKit and system commands.
///
/// Both `UpdateView` (restart-after-update) and `MigrationView` (quit-before-migrate)
/// previously inlined the same `Process()` + `DispatchQueue.global()` +
/// `withCheckedContinuation` boilerplate five times over, bypassing the project's own
/// `ProcessRunning` seam. Consolidating it here removes the duplication and — because it
/// runs through `ProcessRunning` — makes the command construction unit-testable with a
/// fake runner instead of spawning real processes.
public struct RunningProcessService: Sendable {
    private let runner: ProcessRunning
    private let pgrepURL: URL
    private let killURL: URL
    private let killallURL: URL
    private let openURL: URL
    private let applicationTerminator: any ApplicationTerminating

    public init(
        runner: ProcessRunning = ProcessRunner(),
        pgrepURL: URL = SystemPaths.pgrep,
        killURL: URL = SystemPaths.kill,
        killallURL: URL = SystemPaths.killall,
        openURL: URL = SystemPaths.open,
        applicationTerminator: any ApplicationTerminating = WorkspaceApplicationTerminator()
    ) {
        self.runner = runner
        self.pgrepURL = pgrepURL
        self.killURL = killURL
        self.killallURL = killallURL
        self.openURL = openURL
        self.applicationTerminator = applicationTerminator
    }

    /// True when a process whose executable name matches `processName` exactly is running.
    /// `pgrep -x` exits 0 when at least one match exists, non-zero otherwise.
    public func isRunning(_ processName: String) async -> Bool {
        let request = ProcessRequest(executableURL: pgrepURL, arguments: ["-x", processName])
        return (try? await runner.run(request))?.exitCode == 0
    }

    /// Asks an application to quit through AppKit, allowing it to save state or refuse.
    /// The caller still checks `isRunning` because an accepted request does not mean that
    /// shutdown has completed.
    public func requestGracefulTermination(appName: String, processName: String) async -> Bool {
        await applicationTerminator.requestTermination(appName: appName, processName: processName)
    }

    /// Forcefully kills every exact process-name match. This is intentionally separate
    /// from the graceful request: callers must obtain explicit consent and honor `false`.
    public func forceKill(_ processName: String) async -> Bool {
        let request = ProcessRequest(executableURL: killallURL, arguments: ["-KILL", processName])
        return (try? await runner.run(request))?.exitCode == 0
    }

    /// Forcefully terminates only the process the caller identified and confirmed.
    public func forceKill(processIdentifier: Int32) async -> Bool {
        let request = ProcessRequest(
            executableURL: killURL,
            arguments: ["-KILL", String(processIdentifier)]
        )
        return (try? await runner.run(request))?.exitCode == 0
    }

    /// Best-effort terminate every process matching `processName` (`killall <name>`).
    public func kill(_ processName: String) async {
        let request = ProcessRequest(executableURL: killallURL, arguments: [processName])
        _ = try? await runner.run(request)
    }

    /// Relaunch an app by name (`open -a <appName>`).
    public func launch(appName: String) async {
        let request = ProcessRequest(executableURL: openURL, arguments: ["-a", appName])
        _ = try? await runner.run(request)
    }
}
