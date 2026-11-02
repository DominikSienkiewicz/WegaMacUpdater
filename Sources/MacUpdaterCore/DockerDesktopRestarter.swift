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
        guard !Task.isCancelled else { return .cancelled }
        let executable = bundleURL.appendingPathComponent("Contents/Resources/bin/docker")
        guard executableExists(executable) else {
            return .unknown("Docker Desktop CLI is unavailable in the selected app bundle.")
        }
        guard readinessTimeout.isFinite, readinessTimeout > 0, pollInterval.isFinite, pollInterval > 0 else {
            return .unknown("Docker engine readiness requires a positive, finite timeout and polling interval.")
        }
        switch await stopper.stop(bundleURL: bundleURL) {
        case .stopped: break
        case .unsupported:
            return .unknown("Controlled Docker Desktop stop is unavailable. Stop and start Docker Desktop manually.")
        case .failed(let detail): return .stopFailed(detail)
        case .timedOut: return .stopFailed("Docker Desktop did not confirm shutdown before the timeout.")
        case .cancelled: return .cancelled
        }
        do {
            try Task.checkCancellation()
            let started = try await runner.run(request(
                executable: executable, arguments: ["desktop", "start", "--detach"], timeout: 30
            ))
            guard started.exitCode == 0 else {
                return .startFailed(diagnostic(started, fallback: "Docker Desktop start exited with code \(started.exitCode)."))
            }
            return await waitForEngine(executable: executable)
        } catch {
            return cancelled(error) ? .cancelled : .startFailed(error.localizedDescription)
        }
    }

    private func waitForEngine(executable: URL) async -> DockerDesktopRestartResult {
        let deadline = now() + readinessTimeout
        let socket = homeURL.appendingPathComponent(".docker/run/docker.sock").path
        var lastDiagnostic = "The local Docker engine has not responded."
        while now() < deadline {
            do {
                try Task.checkCancellation()
                let response = try await runner.run(request(
                    executable: executable,
                    arguments: ["--host", "unix://" + socket, "info", "--format", "{{.ServerVersion}}"],
                    timeout: min(5, max(0.001, deadline - now()))
                ))
                let serverVersion = response.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if response.exitCode == 0, !serverVersion.isEmpty, serverVersion != "<no value>", now() < deadline {
                    return .ready
                }
                lastDiagnostic = diagnostic(response, fallback: "The local Docker engine did not return its server version.")
            } catch {
                if cancelled(error) { return .cancelled }
                lastDiagnostic = error.localizedDescription
            }
            let remaining = deadline - now()
            guard remaining > 0 else { break }
            do {
                try await sleep(min(pollInterval, remaining))
            } catch {
                return cancelled(error) ? .cancelled : .unknown(error.localizedDescription)
            }
        }
        return Task.isCancelled ? .cancelled : .readinessTimedOut(lastDiagnostic)
    }

    private func request(executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessRequest {
        ProcessRequest(
            executableURL: executable,
            arguments: arguments,
            environment: ["HOME": homeURL.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            inheritParentEnvironment: false,
            timeout: timeout,
            idleTimeout: timeout
        )
    }

    private func diagnostic(_ result: ProcessResult, fallback: String) -> String {
        let detail = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return detail ?? fallback
    }

    private func cancelled(_ error: Error) -> Bool {
        error is CancellationError || error as? ProcessRunnerError == .cancelled || Task.isCancelled
    }
}
