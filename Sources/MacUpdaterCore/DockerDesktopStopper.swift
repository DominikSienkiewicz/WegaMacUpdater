import Foundation

public enum DockerDesktopStopResult: Equatable, Sendable {
    case stopped
    case unsupported
    case failed(String)
    case timedOut
    case cancelled

    public var allowsBundleMutation: Bool { self == .stopped }
}

public protocol DockerDesktopStopping: Sendable {
    func stop(bundleURL: URL) async -> DockerDesktopStopResult
}

public struct DockerDesktopStopper: DockerDesktopStopping {
    private let runner: any ProcessRunning
    private let executableExists: @Sendable (URL) -> Bool
    private let maximumProbes: Int
    private let pause: @Sendable () async throws -> Void

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        executableExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) },
        maximumProbes: Int = 30,
        pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.runner = runner
        self.executableExists = executableExists
        self.maximumProbes = maximumProbes
        self.pause = pause
    }

    public func stop(bundleURL: URL) async -> DockerDesktopStopResult {
        .stopped
    }
}

public enum DockerDesktopMutationGate {
    public static func isDocker(token: String) -> Bool {
        false
    }

    public static func stopIfNeeded(
        token: String,
        bundleURL: URL?,
        stop: @Sendable (URL) async -> DockerDesktopStopResult
    ) async -> DockerDesktopStopResult? {
        nil
    }
}
