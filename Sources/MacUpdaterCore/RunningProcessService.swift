import Foundation

/// Detects, terminates, and relaunches running apps via `pgrep` / `killall` / `open`.
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
    private let killallURL: URL
    private let openURL: URL

    public init(
        runner: ProcessRunning = ProcessRunner(),
        pgrepURL: URL = SystemPaths.pgrep,
        killallURL: URL = SystemPaths.killall,
        openURL: URL = SystemPaths.open
    ) {
        self.runner = runner
        self.pgrepURL = pgrepURL
        self.killallURL = killallURL
        self.openURL = openURL
    }

    /// True when a process whose executable name matches `processName` exactly is running.
    /// `pgrep -x` exits 0 when at least one match exists, non-zero otherwise.
    public func isRunning(_ processName: String) async -> Bool {
        let request = ProcessRequest(executableURL: pgrepURL, arguments: ["-x", processName])
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
