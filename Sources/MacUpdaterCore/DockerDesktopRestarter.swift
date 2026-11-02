import Foundation

public enum DockerDesktopRestartResult: Equatable, Sendable {
    case ready
    case stopFailed(String)
    case startFailed(String)
    case readinessTimedOut(String)
    case unknown(String)
    case cancelled

    public var engineReady: Bool { self == .ready }
}

public struct DockerDesktopRestarter: Sendable {
    private let runner: any ProcessRunning
    private let stopper: any DockerDesktopStopping
    private let homeURL: URL
    private let readinessTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let executableExists: @Sendable (URL) -> Bool

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        stopper: any DockerDesktopStopping = DockerDesktopStopper(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        readinessTimeout: TimeInterval = 120,
        pollInterval: TimeInterval = 2,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        executableExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) {
        self.runner = runner
        self.stopper = stopper
        self.homeURL = homeURL
        self.readinessTimeout = readinessTimeout
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
        self.executableExists = executableExists
    }

    public func restart(bundleURL: URL) async -> DockerDesktopRestartResult {
        .unknown("Docker engine readiness has not been checked.")
    }
}
