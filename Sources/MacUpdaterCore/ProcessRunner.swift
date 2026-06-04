import Foundation

public struct ProcessRequest: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var timeout: TimeInterval?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessOutputEvent: Equatable, Sendable {
    case stdout(String)
    case stderr(String)
    case finished(ProcessResult)
}

public enum ProcessRunnerError: Error, Equatable, LocalizedError {
    case timedOut(seconds: TimeInterval)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "Process timed out after \(seconds) seconds."
        case .cancelled:
            return "Process was cancelled."
        }
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error>
}

public final class ProcessRunner: ProcessRunning, Sendable {
    public init() {}

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try await run(request, onOutput: nil)
    }

    public func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let onOutput: @Sendable (ProcessOutputEvent) -> Void = { event in
                        continuation.yield(event)
                    }
                    let result = try await self.run(request, onOutput: onOutput)
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func run(
        _ request: ProcessRequest,
        onOutput: (@Sendable (ProcessOutputEvent) -> Void)?
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let operation: @Sendable () throws -> ProcessResult = {
            try Self.runSynchronously(request, onOutput: onOutput)
        }
        return try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    private static func runSynchronously(
        _ request: ProcessRequest,
        onOutput: (@Sendable (ProcessOutputEvent) -> Void)?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments

        if !request.environment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            request.environment.forEach { key, value in
                environment[key] = value
            }
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = LockedData()
        let stderrBuffer = LockedData()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                onOutput?(.stdout(chunk))
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                onOutput?(.stderr(chunk))
            }
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()

        let startedAt = Date()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw ProcessRunnerError.cancelled
            }

            if let timeout = request.timeout, Date().timeIntervalSince(startedAt) >= timeout {
                process.terminate()
                process.waitUntilExit()
                throw ProcessRunnerError.timedOut(seconds: timeout)
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdoutRemainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrRemainder = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutBuffer.append(stdoutRemainder)
        stderrBuffer.append(stderrRemainder)

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutBuffer.data, as: UTF8.self),
            stderr: String(decoding: stderrBuffer.data, as: UTF8.self)
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}
