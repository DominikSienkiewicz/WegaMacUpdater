import Foundation
import Darwin

public struct ProcessRequest: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var inheritParentEnvironment: Bool
    public var timeout: TimeInterval?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        inheritParentEnvironment: Bool = true,
        timeout: TimeInterval? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.inheritParentEnvironment = inheritParentEnvironment
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
    public init() { /* stateless; explicit so the initializer is public across the module boundary */ }

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try await run(request, onOutput: nil)
    }

    public func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.pump(request, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs `request`, forwarding each output event into `continuation` and finishing
    /// the stream when the process exits (or throwing on failure). Extracted from
    /// `events(for:)` so the streaming logic isn't nested three closures deep.
    private func pump(
        _ request: ProcessRequest,
        into continuation: AsyncThrowingStream<ProcessOutputEvent, Error>.Continuation
    ) async {
        do {
            let onOutput: @Sendable (ProcessOutputEvent) -> Void = { continuation.yield($0) }
            let result = try await run(request, onOutput: onOutput)
            continuation.yield(.finished(result))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
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
        // The blocking synchronous body (semaphore waits + pipe drains) runs on a detached
        // task so it never parks a cooperative-pool thread. A detached task does not inherit
        // cancellation, so forward it explicitly: without this the `Task.isCancelled` guards
        // inside `runSynchronously` could never fire and a cancelled caller would leave the
        // subprocess — and everything it spawned — running (REL-12).
        let work = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func runSynchronously(
        _ request: ProcessRequest,
        onOutput: (@Sendable (ProcessOutputEvent) -> Void)?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments

        if !request.environment.isEmpty {
            var environment = request.inheritParentEnvironment
                ? ProcessInfo.processInfo.environment
                : [:]
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

        // Abandon a still-running process: kill the whole tree, let it die, drop the
        // handlers, discard partial output, and surface `error`. We don't wait on `ioGroup`
        // here — a leaked grandchild could hold the pipe open and EOF would never come.
        let abort: (ProcessRunnerError) throws -> Never = { error in
            Self.terminateProcessTree(process)
            exitSemaphore.wait()
            detachHandlers()
            WegaLog.error(
                .process,
                "\(request.executableURL.lastPathComponent) aborted: \(error.localizedDescription)"
            )
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

        let result = ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutBuffer.data, as: UTF8.self),
            stderr: String(decoding: stderrBuffer.data, as: UTF8.self)
        )
        // Non-zero is often domain-meaningful (handled by callers), so keep it at
        // debug — available for diagnosis without escalating it to a warning/error.
        if result.exitCode != 0 {
            WegaLog.debug(
                .process,
                "\(request.executableURL.lastPathComponent) exited \(result.exitCode)"
            )
        }
        return result
    }

    /// Kills the subprocess *and every descendant it spawned*, not just the immediate
    /// child. Foundation launches each subprocess as the leader of a fresh process group
    /// (`pgid == child pid`), and a non-interactive shell keeps its background jobs in that
    /// same group. `terminate()` signals only the leader, so a spawned grandchild (e.g. a
    /// backgrounded `sleep`) would be orphaned and outlive the cancellation. Signalling the
    /// whole process group reaps the entire tree in one shot (REL-12).
    ///
    /// The `group != ownGroup` guard makes it impossible to signal our own process group:
    /// if the platform ever kept the child in the caller's group we fall back to a plain
    /// `terminate()` rather than taking the updater down with the subprocess.
    private static func terminateProcessTree(_ process: Process) {
        let pid = process.processIdentifier
        let group = getpgid(pid)
        let ownGroup = getpgid(0)
        process.terminate()
        if group > 0 && group != ownGroup {
            _ = killpg(group, SIGKILL)
        }
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
