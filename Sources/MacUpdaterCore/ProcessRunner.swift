import Foundation
import Darwin

public struct ProcessRequest: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var inheritParentEnvironment: Bool
    /// Wall-clock budget from launch to exit. Defaults to a bounded value (REL-12): an
    /// operation with no deadline at all is what let a stuck CLI hold the app forever.
    public var timeout: TimeInterval?
    /// How long the process may produce no output before it counts as hung (REL-12).
    public var idleTimeout: TimeInterval?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        inheritParentEnvironment: Bool = true,
        timeout: TimeInterval? = ProcessTimeoutPolicy.default.deadline,
        idleTimeout: TimeInterval? = ProcessTimeoutPolicy.default.idle
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.inheritParentEnvironment = inheritParentEnvironment
        self.timeout = timeout
        self.idleTimeout = idleTimeout
    }

    /// Preferred spelling at the call sites: name the *kind* of operation and let the
    /// policy supply both limits, so a new command cannot be added with only one of them.
    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        inheritParentEnvironment: Bool = true,
        timeouts: ProcessTimeoutPolicy
    ) {
        self.init(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            inheritParentEnvironment: inheritParentEnvironment,
            timeout: timeouts.deadline,
            idleTimeout: timeouts.idle
        )
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
    /// The process was still alive but had produced no output for `seconds` (REL-12).
    /// Told apart from `timedOut` on purpose: one means "too slow", the other "stuck".
    case idleTimedOut(seconds: TimeInterval)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "Process timed out after \(seconds) seconds."
        case .idleTimedOut(let seconds):
            return "Process produced no output for \(seconds) seconds."
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
    /// Process-wide ceiling on how many external processes may run at once. A large
    /// `/Applications` scan fans out ~12 checks, several of which shell out to
    /// `brew`/`npm`/`mas`; without a shared ceiling their subprocesses could all pile up
    /// at once. Bound to the core count (with a small floor) so heavy subprocesses never
    /// outnumber the cores that back them, while staying generous enough not to serialise
    /// an ordinary scan (ARCH-02).
    static let defaultMaxConcurrentProcesses = max(4, ProcessInfo.processInfo.activeProcessorCount)

    /// Per-stream cap on captured output. `stdout`/`stderr` roll to keep the most recent
    /// bytes rather than growing without bound, so a runaway process printing gigabytes
    /// cannot exhaust memory. Sized far above any real `brew`/`npm`/`mas` output, so
    /// ordinary command output is captured in full and only pathological output is
    /// trimmed (ARCH-02).
    static let defaultMaxCapturedBytesPerStream = 8 * 1024 * 1024

    /// How long a process gets between the polite SIGTERM and the unconditional SIGKILL
    /// (REL-12). Long enough for `brew` to unwind — release its lock, remove a half-written
    /// staging directory — and short enough that "Anuluj" still feels immediate.
    static let terminationGracePeriod: TimeInterval = 2

    /// Shared so that every ad-hoc `ProcessRunner()` (each service defaults to its own)
    /// draws from ONE process-wide budget — a per-instance gate would not bound the total.
    private static let sharedLimiter = ProcessLimiter(limit: ProcessRunner.defaultMaxConcurrentProcesses)

    private let limiter: ProcessLimiter
    private let maxCapturedBytesPerStream: Int

    public init() {
        self.limiter = Self.sharedLimiter
        self.maxCapturedBytesPerStream = Self.defaultMaxCapturedBytesPerStream
    }

    /// Test/inspection seam: an isolated concurrency gate and a small capture cap so a
    /// bound can be observed without generating megabytes or contending with the shared
    /// process-wide limiter.
    init(limiter: ProcessLimiter, maxCapturedBytesPerStream: Int = ProcessRunner.defaultMaxCapturedBytesPerStream) {
        self.limiter = limiter
        self.maxCapturedBytesPerStream = maxCapturedBytesPerStream
    }

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

        // Bounded concurrency: hold a permit for the process's whole lifetime. Because the
        // wait below suspends on a continuation (never a blocked thread), a held permit
        // parks no pool thread — the gate throttles process count without starving the
        // async runtime (ARCH-02).
        await limiter.acquire()
        defer { Task { await limiter.release() } }

        // We may have queued for a permit; a caller cancelled meanwhile never launches.
        try Task.checkCancellation()

        return try await Self.runProcess(
            request,
            onOutput: onOutput,
            maxCapturedBytesPerStream: maxCapturedBytesPerStream
        )
    }

    private static func runProcess(
        _ request: ProcessRequest,
        onOutput: (@Sendable (ProcessOutputEvent) -> Void)?,
        maxCapturedBytesPerStream: Int
    ) async throws -> ProcessResult {
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

        // Rolling buffers: every chunk is streamed live through `onOutput`, but the
        // accumulated capture keeps only the most recent `maxCapturedBytesPerStream`
        // bytes, so a huge output never grows the captured buffer without bound (ARCH-02).
        let stdoutBuffer = RollingBuffer(capacity: maxCapturedBytesPerStream)
        let stderrBuffer = RollingBuffer(capacity: maxCapturedBytesPerStream)
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        // REL-12 — every chunk on either stream rearms the inactivity timer. Started now,
        // before `run()`, so a process that never prints anything is measured from launch.
        let activity = OutputActivity()

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
            activity.touch()
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
            activity.touch()
            stderrBuffer.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                onOutput?(.stderr(chunk))
            }
        }

        // Resume the async wait the instant the process exits, from the termination
        // handler — no polling, no thread parked on a semaphore.
        let termination = TerminationSignal()
        process.terminationHandler = { _ in termination.signal() }

        try process.run()

        let detachHandlers: () -> Void = {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
        }

        let outcome = await Self.awaitExit(
            process: process,
            termination: termination,
            activity: activity,
            timeout: request.timeout,
            idleTimeout: request.idleTimeout
        )

        // Abandon a still-running process: the tree is already killed by `awaitExit`, so
        // drop the handlers, discard partial output, and surface the error. We don't wait
        // on `ioGroup` here — a leaked grandchild could hold the pipe open and EOF would
        // never come.
        switch outcome {
        case .cancelled:
            detachHandlers()
            WegaLog.error(
                .process,
                "\(request.executableURL.lastPathComponent) aborted: \(ProcessRunnerError.cancelled.localizedDescription)"
            )
            throw ProcessRunnerError.cancelled
        case .timedOut(let seconds):
            detachHandlers()
            WegaLog.error(
                .process,
                "\(request.executableURL.lastPathComponent) aborted: \(ProcessRunnerError.timedOut(seconds: seconds).localizedDescription)"
            )
            throw ProcessRunnerError.timedOut(seconds: seconds)
        case .idleTimedOut(let seconds):
            detachHandlers()
            WegaLog.error(
                .process,
                "\(request.executableURL.lastPathComponent) aborted: \(ProcessRunnerError.idleTimedOut(seconds: seconds).localizedDescription)"
            )
            throw ProcessRunnerError.idleTimedOut(seconds: seconds)
        case .completed:
            break
        }

        // Process has exited; wait — without blocking a thread — for both handlers to
        // observe EOF so every buffered byte is captured before we read the buffers.
        await Self.waitForIO(ioGroup)

        let result = ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBuffer.string(),
            stderr: stderrBuffer.string()
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

    private enum ExitOutcome: Sendable {
        case completed
        case timedOut(TimeInterval)
        case idleTimedOut(TimeInterval)
        case cancelled
    }

    /// Awaits the process exit, racing the wall-clock deadline, the inactivity timeout and
    /// cooperative cancellation. Whichever fires first kills the whole process tree so the
    /// termination signal arrives and the wait can always unwind — a checked continuation
    /// ignores cancellation, so the subprocess is what releases it.
    private static func awaitExit(
        process: Process,
        termination: TerminationSignal,
        activity: OutputActivity,
        timeout: TimeInterval?,
        idleTimeout: TimeInterval?
    ) async -> ExitOutcome {
        // `Process` is not `Sendable`; the only operations the cancellation handler runs on
        // it (terminate/kill) are individually thread-safe, so cross the boundary explicitly.
        let box = UncheckedSendableBox(process)
        return await withTaskCancellationHandler {
            await raceExit(
                process: box,
                termination: termination,
                activity: activity,
                timeout: timeout,
                idleTimeout: idleTimeout
            )
        } onCancel: {
            Self.terminateProcessTree(box.value)
        }
    }

    private static func raceExit(
        process: UncheckedSendableBox<Process>,
        termination: TerminationSignal,
        activity: OutputActivity,
        timeout: TimeInterval?,
        idleTimeout: TimeInterval?
    ) async -> ExitOutcome {
        await withTaskGroup(of: ExitOutcome.self) { group in
            group.addTask {
                await termination.wait()
                return .completed
            }
            if let timeout {
                group.addTask {
                    // A thrown (nil) sleep means the process already exited and we were
                    // cancelled out of the group — that value is discarded below.
                    if (try? await Task.sleep(for: .seconds(timeout))) == nil {
                        return .completed
                    }
                    return .timedOut(timeout)
                }
            }
            if let idleTimeout {
                group.addTask { await Self.awaitSilence(activity: activity, limit: idleTimeout) }
            }

            let winner = await group.next() ?? .completed
            switch winner {
            case .timedOut, .idleTimedOut:
                Self.terminateProcessTree(process.value)
            case .completed, .cancelled:
                break
            }
            group.cancelAll()
            await group.waitForAll()

            // A cancellation request outranks a natural finish: the caller asked to stop.
            if Task.isCancelled { return .cancelled }
            return winner
        }
    }

    /// Resolves once the process has been quiet for `limit` seconds. Sleeps exactly as long
    /// as the *current* silence still has to run, so each new chunk of output effectively
    /// rearms the timer without a polling loop that wakes up for nothing.
    private static func awaitSilence(activity: OutputActivity, limit: TimeInterval) async -> ExitOutcome {
        while true {
            let remaining = limit - activity.secondsSinceLastOutput()
            if remaining <= 0 { return .idleTimedOut(limit) }
            // A thrown (nil) sleep means the process exited and the group cancelled us.
            if (try? await Task.sleep(for: .seconds(remaining))) == nil { return .completed }
        }
    }

    /// Suspends until both pipe readers have observed EOF, without blocking a thread.
    private static func waitForIO(_ group: DispatchGroup) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }
    }

    /// Stops the subprocess *and every descendant it spawned*, not just the immediate child,
    /// as a two-phase sequence: **SIGTERM → grace period → SIGKILL** (REL-12).
    ///
    /// Why the whole group: Foundation launches each subprocess as the leader of a fresh
    /// process group (`pgid == child pid`), and a non-interactive shell keeps its background
    /// jobs in that same group. Signalling only the leader orphans a spawned grandchild
    /// (e.g. a backgrounded `sleep`), which then outlives the cancellation.
    ///
    /// Why the grace period: an immediate SIGKILL gives `brew` no chance to release its
    /// lock or clean up a half-written staging directory, and a signal handler in the tool
    /// never runs. The escalation is what keeps that politeness bounded — a process that
    /// ignores SIGTERM is killed anyway once the grace period expires, so "Anuluj" cannot
    /// hang on a stubborn CLI.
    ///
    /// The `group != ownGroup` guard makes it impossible to signal our own process group:
    /// if the platform ever kept the child in the caller's group we fall back to signalling
    /// the child alone rather than taking the updater down with the subprocess.
    private static func terminateProcessTree(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let group = getpgid(pid)
        let signalsWholeGroup = group > 0 && group != getpgid(0)

        if signalsWholeGroup {
            _ = killpg(group, SIGTERM)
        } else {
            process.terminate()
        }

        // Detached on purpose: the escalation has to outlive this call, which returns
        // immediately (it is also invoked from a synchronous cancellation handler).
        let box = UncheckedSendableBox(process)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(Self.terminationGracePeriod))
            guard signalsWholeGroup else {
                if box.value.isRunning { _ = kill(pid, SIGKILL) }
                return
            }
            // `killpg(_, 0)` asks whether *anything* in the tree is still alive — the leader
            // may well have honoured SIGTERM while a descendant ignored it.
            if killpg(group, 0) == 0 { _ = killpg(group, SIGKILL) }
        }
    }
}

/// Tracks when a process last produced output, so the inactivity timeout measures silence
/// rather than total runtime (REL-12). Monotonic (`DispatchTime`) so a clock adjustment —
/// or the machine sleeping mid-download — cannot make a healthy process look hung.
private final class OutputActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastOutput = DispatchTime.now()

    func touch() {
        lock.lock()
        lastOutput = DispatchTime.now()
        lock.unlock()
    }

    func secondsSinceLastOutput() -> TimeInterval {
        lock.lock()
        let last = lastOutput
        lock.unlock()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds
        return TimeInterval(elapsed) / 1_000_000_000
    }
}

/// A wrapper that lets a value cross into a `@Sendable` closure when the programmer, not
/// the compiler, is responsible for the safety of the operations performed on it.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// One-shot async signal: `wait()` suspends on a checked continuation that `signal()`
/// resumes exactly once, whichever happens first. Used to await a process's
/// `terminationHandler` without parking a pool thread.
private final class TerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        if hasFired {
            lock.unlock()
            return
        }
        hasFired = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if hasFired {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// An async counting semaphore. `acquire()` suspends on a continuation when no permit is
/// free (parking no thread); `release()` hands the permit to the next waiter or returns
/// it to the pool. Bounds how many external processes `ProcessRunner` runs at once.
/// An `actor` rather than a lock-guarded class: `NSLock.lock()` is unavailable from async
/// contexts under Swift 6 strict concurrency, because blocking a cooperative-pool thread is
/// exactly what this type exists to avoid. Actor isolation gives the same mutual exclusion
/// without parking a thread, and the continuation bookkeeping stays serialised for free.
actor ProcessLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        // The closure runs synchronously, still inside the actor, before this task suspends —
        // so a permit released in the meantime cannot be missed.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Hands the permit straight to the next waiter instead of returning it to the pool, so a
    /// queued caller cannot be overtaken by one arriving later.
    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// A fixed-capacity capture buffer that keeps the most recent `capacity` bytes. Appends
/// are amortised O(1): the backing store is trimmed only after it grows past twice the
/// capacity, so the live footprint never exceeds `2 * capacity`.
private final class RollingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var storage = Data()

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    func append(_ data: Data) {
        guard !data.isEmpty, capacity > 0 else { return }
        lock.lock()
        storage.append(data)
        if storage.count > capacity * 2 {
            storage.removeFirst(storage.count - capacity)
        }
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        let tail = storage.count > capacity ? storage.suffix(capacity) : storage[...]
        return String(decoding: tail, as: UTF8.self)
    }
}
