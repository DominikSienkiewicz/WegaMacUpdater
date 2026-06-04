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
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // Each pipe is drained exclusively by its readability handler, all the way to
        // EOF (an empty `availableData`). The descriptor is never read from a second
        // place (no `readDataToEndOfFile` after the loop), so there is no window where
        // two readers race over the same bytes. `ioGroup` tracks the two EOFs so the
        // success path can wait until every byte has been delivered.
        let ioGroup = DispatchGroup()
        ioGroup.enter()
        ioGroup.enter()

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                ioGroup.leave()
                return
            }
            stdoutBuffer.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                onOutput?(.stdout(chunk))
            }
        }

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                ioGroup.leave()
                return
            }
            stderrBuffer.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                onOutput?(.stderr(chunk))
            }
        }

        // Wake instantly when the process exits instead of polling `isRunning` on a
        // sleep loop.
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        try process.run()

        let detachHandlers: () -> Void = {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
        }

        // Abandon a still-running process: terminate, let it die, drop the handlers,
        // discard partial output, and surface `error`. We don't wait on `ioGroup`
        // here — a leaked grandchild could hold the pipe open and EOF would never come.
        let abort: (ProcessRunnerError) throws -> Never = { error in
            process.terminate()
            exitSemaphore.wait()
            detachHandlers()
            throw error
        }

        let startedAt = Date()
        // Block on the exit semaphore in short slices so cancellation and timeout are
        // still observed; the slice is a watchdog interval, not a busy-wait — a normal
        // exit unblocks immediately via `terminationHandler`.
        while exitSemaphore.wait(timeout: .now() + 0.1) == .timedOut {
            if Task.isCancelled {
                try abort(.cancelled)
            }
            if let timeout = request.timeout, Date().timeIntervalSince(startedAt) >= timeout {
                try abort(.timedOut(seconds: timeout))
            }
        }

        // Process has exited; wait for both handlers to observe EOF so every buffered
        // byte is captured before we read the buffers.
        ioGroup.wait()

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
