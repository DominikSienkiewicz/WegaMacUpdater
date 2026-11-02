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
        do {
            try Task.checkCancellation()
            guard bundleURL.isFileURL, bundleURL.pathExtension == "app" else {
                return .failed("Docker Desktop bundle path is unavailable.")
            }
            let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            if try await hasExited(bundle: bundle) { return .stopped }
            let executable = bundle.appendingPathComponent("Contents/Resources/cli-plugins/docker-desktop")
            guard executableExists(executable) else { return .unsupported }
            let result = try await runner.run(ProcessRequest(
                executableURL: executable,
                arguments: ["desktop", "stop", "--timeout", "60"],
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
                ],
                inheritParentEnvironment: false,
                timeouts: .init(deadline: 65, idle: 65)
            ))
            guard result.exitCode == 0 else {
                return .failed("Docker Desktop stop exited \(result.exitCode): \(result.stderr)")
            }
            for attempt in 0..<max(1, maximumProbes) {
                try Task.checkCancellation()
                if try await hasExited(bundle: bundle) { return .stopped }
                if attempt + 1 < maximumProbes { try await pause() }
            }
            return .timedOut
        } catch is CancellationError {
            return .cancelled
        } catch let error as ProcessRunnerError {
            switch error {
            case .cancelled: return .cancelled
            case .timedOut, .idleTimedOut: return .timedOut
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func hasExited(bundle: URL) async throws -> Bool {
        let path = NSRegularExpression.escapedPattern(for: bundle.appendingPathComponent("Contents").path + "/")
        // Homebrew may move a bundle while processes from its old path still own the VM.
        let backend = "(^|/)com[.]docker[.](backend|virtualization|hyperkit|krun|sailor|driver[.]amd64-linux)([[:space:]]|$)"
        let desktop = "(^|/)Docker Desktop[.]app/Contents/MacOS/Docker Desktop([[:space:]]|$)"
        let legacy = "(^|/)Docker[.]app/Contents/MacOS/Docker([[:space:]]|$)"
        let pattern = ["^" + path, backend, desktop, legacy].joined(separator: "|")
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", pattern],
            timeouts: .init(deadline: 2, idle: 2)
        ))
        switch result.exitCode {
        case 0: return false
        case 1: return true
        default: throw ProbeError.unavailable(result.exitCode)
        }
    }

    private enum ProbeError: Error, LocalizedError {
        case unavailable(Int32)

        var errorDescription: String? {
            switch self {
            case .unavailable(let code): return "Cannot confirm Docker Desktop process exit (pgrep: \(code))."
            }
        }
    }
}

public enum DockerDesktopMutationGate {
    public static func isDocker(token: String) -> Bool {
        let name = token.split(separator: "/").last.map(String.init)?.lowercased()
        return name == "docker" || name == "docker-desktop"
    }

    public static func stopIfNeeded(
        token: String,
        bundleURL: URL?,
        stop: @Sendable (URL) async -> DockerDesktopStopResult
    ) async -> DockerDesktopStopResult? {
        guard isDocker(token: token) else { return nil }
        guard let bundleURL else { return .failed("Docker Desktop bundle path is unavailable.") }
        let result = await stop(bundleURL)
        UpdateDiagnostics.record("docker.shutdown", fields: [
            "token": token, "bundlePath": bundleURL.path,
            "result": String(describing: result), "allowsBundleMutation": String(result.allowsBundleMutation)
        ])
        return result
    }
}
