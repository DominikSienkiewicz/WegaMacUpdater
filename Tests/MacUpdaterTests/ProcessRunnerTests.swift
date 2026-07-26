import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    /// Regression: the final `readDataToEndOfFile()` used to run while the pipe's
    /// `readabilityHandler` was still installed (the `defer` that niled it fired only
    /// at function exit). Two concurrent readers on the same descriptor split or
    /// duplicate bytes, corrupting captured stdout on large outputs (e.g. a long
    /// `brew install` log). The captured stdout must equal the process output exactly.
    @Test func capturesLargeOutputWithoutLossOrDuplication() async throws {
        let runner = ProcessRunner()
        let count = 200_000
        let expected = (1...count).map(String.init).joined(separator: "\n") + "\n"

        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "\(count)"]
        )

        // Run several times: the read race is probabilistic, so a single pass can
        // slip through even on the buggy code. Any corrupted run fails the test.
        for iteration in 0..<10 {
            let result = try await runner.run(request)
            #expect(result.exitCode == 0)
            #expect(result.stdout == expected, "stdout corrupted on iteration \(iteration)")
        }
    }

    /// The streaming `events(for:)` path drains the same pipes via the same handlers.
    /// Concatenating every `.stdout` chunk must reconstruct the process output exactly,
    /// and the trailing `.finished` result must carry the same complete buffer.
    @Test func streamsLargeOutputWithoutLossOrDuplication() async throws {
        let runner = ProcessRunner()
        let count = 200_000
        let expected = (1...count).map(String.init).joined(separator: "\n") + "\n"

        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "\(count)"]
        )

        var streamed = ""
        var finished: ProcessResult?
        for try await event in runner.events(for: request) {
            switch event {
            case .stdout(let chunk): streamed += chunk
            case .stderr: break
            case .finished(let result): finished = result
            }
        }

        #expect(streamed == expected)
        #expect(finished?.exitCode == 0)
        #expect(finished?.stdout == expected)
    }

    /// A process that outlives its timeout is terminated and surfaces `.timedOut`.
    @Test func enforcesTimeout() async throws {
        let runner = ProcessRunner()
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.5
        )

        await #expect(throws: ProcessRunnerError.timedOut(seconds: 0.5)) {
            _ = try await runner.run(request)
        }
    }

    /// Cancellation propagation (REL-12): a caller whose task is already cancelled must not
    /// spawn the subprocess at all. `run` opens with `Task.checkCancellation()`, so the call
    /// throws `CancellationError` before `/bin/sleep` is ever launched.
    ///
    /// Determinism: the task suspends on a long `Task.sleep` until the test cancels it, so by
    /// the time `run` executes its guard `Task.isCancelled` is already true regardless of
    /// scheduling order. The `timeout` is belt-and-suspenders — if the guard ever regressed,
    /// the process would surface `.timedOut` in 2s instead of hanging the suite for an hour.
    @Test func aCancelledCallerNeverLaunchesTheProcess() async {
        let runner = ProcessRunner()
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["3600"],
            timeout: 2
        )

        let task = Task { () -> ProcessResult in
            try? await Task.sleep(for: .seconds(3600))
            return try await runner.run(request)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
