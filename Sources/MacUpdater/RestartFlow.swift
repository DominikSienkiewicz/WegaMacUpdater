import MacUpdaterCore

/// Restart after an update: ask the app to quit, wait for it, relaunch. Never forces —
/// an app that does not quit within the wait is handed back so the user can decide.
struct RestartFlow: Sendable {
    enum Outcome: Equatable {
        case relaunched
        case needsForce
    }

    static let pollInterval: Duration = .milliseconds(500)
    static let maximumPolls = 20

    var requestQuit: @Sendable (RestartInfo) async -> Bool
    var isRunning: @Sendable (String) async -> Bool
    var launch: @Sendable (String) async -> Void
    var pause: @Sendable (Duration) async -> Void

    func run(_ info: RestartInfo) async -> Outcome {
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
}
