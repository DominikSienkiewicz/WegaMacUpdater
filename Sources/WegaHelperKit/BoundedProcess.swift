import Darwin
import Foundation

/// REL-12, one module down — a synchronous command that cannot wait forever.
///
/// `ProcessRunner` in `MacUpdaterCore` is the bounded path for everything the update pipeline
/// runs, and its guard refuses any unbounded wait there. It cannot be used here: `WegaHelperKit`
/// is the base module — the root daemon links it precisely so it does *not* pull in Core — so
/// the dependency only points one way, and `ProcessRunner` is async besides.
///
/// That left `CodeSignatureVerifier` waiting on `codesign`, `spctl`, `pkgutil` and `hdiutil`
/// with a bare `waitUntilExit()`. The one that matters is `hdiutil attach`: a damaged or
/// truncated disk image can leave it wedged, and because the self-update mounts its `.dmg`
/// through exactly that call, the update hangs with no deadline and nothing to cancel.
///
/// So this is the same contract in the shape this layer can have — synchronous, and small
/// enough to read in one sitting. The *policies* are shared rather than restated:
/// `ProcessTimeoutPolicy` now lives here too, so both layers name their limits from one place.
///
/// # Why the escalation matters
///
/// A process past its deadline gets the polite signal first, a short grace period, and only
/// then the unconditional one — the same sequence `ProcessRunner` uses. `hdiutil` in particular
/// has a mount to unwind; killing it outright is how a half-attached image and a stray
/// `/Volumes` entry get left behind.
public enum BoundedProcess {
    public struct Result: Equatable, Sendable {
        public let exitCode: Int32
        public let standardOutput: String
        public let standardError: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case launchFailed(String)
        case timedOut(seconds: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let message):
                return "Nie udało się uruchomić polecenia: \(message)"
            case .timedOut(let seconds):
                return "Polecenie nie zakończyło się w ciągu \(Int(seconds)) s i zostało zatrzymane."
            }
        }
    }

    /// How long a stopped process gets between the polite signal and the unconditional one.
    /// Matches `ProcessRunner`'s grace period, for the same reason: long enough to unwind,
    /// short enough not to be a second wait.
    static let terminationGracePeriod: TimeInterval = 2

    /// Runs `executable` and returns once it exits — or stops it once `timeouts.deadline`
    /// passes, whichever comes first.
    ///
    /// Output is read after the process exits, not while it runs. These commands report a line
    /// or two, so the pipe buffer is never the limit; a command that did flood it would block
    /// itself, hit the deadline and be stopped — a bounded failure rather than the unbounded
    /// wait this type exists to remove.
    public static func run(
        _ executable: URL,
        arguments: [String],
        timeouts: ProcessTimeoutPolicy
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeouts.deadline) == .timedOut {
            stop(process)
            throw Failure.timedOut(seconds: timeouts.deadline)
        }

        return Result(
            exitCode: process.terminationStatus,
            standardOutput: read(outputPipe),
            standardError: read(errorPipe)
        )
    }

    /// Polite signal, grace, then the unconditional one.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(terminationGracePeriod)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private static func read(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
