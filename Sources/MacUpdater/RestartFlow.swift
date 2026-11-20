import MacUpdaterCore

/// Restart after an update: ask the app to quit, wait for it, relaunch. Never forces on its
/// own — an app that does not quit within the wait is handed back so the user can decide,
/// and `force(_:)` runs only on that consent.
struct RestartFlow: Sendable {
    enum Outcome: Equatable {
        case relaunched
        case needsForce
    }

    static let pollInterval: Duration = .milliseconds(500)
    static let maximumPolls = 20

    enum ForceOutcome: Equatable {
        case relaunched
        case stillRunning
    }

    static let settleAfterKill: Duration = .milliseconds(800)

    var requestQuit: @Sendable (RestartInfo) async -> Bool
    var isRunning: @Sendable (String) async -> Bool
    var launch: @Sendable (String) async -> Void
    var pause: @Sendable (Duration) async -> Void
    var forceKill: @Sendable (String) async -> Bool = { _ in false }

    func run(_ info: RestartInfo) async -> Outcome {
        guard await isRunning(info.processName) else {
            await launch(info.appName)
            return .relaunched
        }
        guard await requestQuit(info) else { return .needsForce }
        for _ in 0..<Self.maximumPolls {
            if !(await isRunning(info.processName)) {
                await launch(info.appName)
                return .relaunched
            }
            await pause(Self.pollInterval)
        }
        return .needsForce
    }

    /// The user agreed to force. A kill that fails is a failure only while the app still runs:
    /// one that quit on its own while the alert was up leaves `killall` nothing to kill, and is
    /// relaunched like any other closed app.
    func force(_ info: RestartInfo) async -> ForceOutcome {
        if await forceKill(info.processName) {
            await pause(Self.settleAfterKill)
        } else if await isRunning(info.processName) {
            return .stillRunning
        }
        await launch(info.appName)
        return .relaunched
    }
}
