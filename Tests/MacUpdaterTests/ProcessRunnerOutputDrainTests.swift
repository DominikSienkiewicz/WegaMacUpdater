import Testing
import Foundation
@testable import MacUpdaterCore

/// M5 — a job that a login shell starts in the background inherits the shell's stdout, so
/// end-of-output can arrive long after the shell itself has exited. Without a bound the run
/// waited for it indefinitely and ignored cancellation, which kept the Cleanup screen stuck on
/// "reading PATH" until the app restarted. `outputDrainLimit` bounds that wait, lets the caller
/// cancel it, and never kills or starves the job that still holds the output.
@Suite("ProcessRunner output drain")
struct ProcessRunnerOutputDrainTests {
    private static let shell = URL(filePath: "/bin/sh", directoryHint: .notDirectory)
    private static let shellLeavingABackgroundJob = "printf ready; sleep 20 &"

    @Test func aDrainLimitReturnsWhileABackgroundJobHoldsTheOutput() async throws {
        var request = ProcessRequest(
            executableURL: Self.shell,
            arguments: ["-c", Self.shellLeavingABackgroundJob],
            timeout: 30,
            idleTimeout: 30
        )
        request.outputDrainLimit = 0.5
        let clock = ContinuousClock()
        let start = clock.now

        let result = try await Self.isolatedRunner().run(request)

        #expect(result.exitCode == 0)
        #expect(result.stdout == "ready")
        #expect(start.duration(to: clock.now) < .seconds(10))
    }

    /// Closing the pipes when the wait expires would hand the job a SIGPIPE on its next write;
    /// the marker is written only after that write, so it proves the job lived on. The late
    /// write is read a second before the marker appears, and must not be forwarded any more.
    @Test func aLateWriterIsNotKilledByTheDrain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "wega-output-drain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mark = directory.appending(path: "late-writer-finished", directoryHint: .notDirectory)
        var request = ProcessRequest(
            executableURL: Self.shell,
            arguments: ["-c", "printf ready; (sleep 2; printf late; sleep 1; touch \"$MARK\") &"],
            environment: ["MARK": mark.path],
            timeout: 30,
            idleTimeout: 30
        )
        request.outputDrainLimit = 0.5
        let (chunks, chunkSink) = AsyncStream.makeStream(of: String.self)

        let result = try await Self.isolatedRunner().run(request, onOutput: { event in
            if case .stdout(let chunk) = event { chunkSink.yield(chunk) }
        })

        #expect(result.stdout == "ready")
        #expect(await Self.fileAppears(at: mark, within: .seconds(10)))
        chunkSink.finish()
        var forwarded: [String] = []
        for await chunk in chunks { forwarded.append(chunk) }
        #expect(forwarded == ["ready"])
    }

    @Test func cancellingDuringTheDrainThrowsCancelled() async throws {
        var request = ProcessRequest(
            executableURL: Self.shell,
            arguments: ["-c", Self.shellLeavingABackgroundJob],
            timeout: 30,
            idleTimeout: 30
        )
        request.outputDrainLimit = 60
        let runner = Self.isolatedRunner()
        let (chunks, chunkSink) = AsyncStream.makeStream(of: String.self)
        let reading = Task {
            try await runner.run(request, onOutput: { event in
                if case .stdout(let chunk) = event { chunkSink.yield(chunk) }
            })
        }
        var receivedChunks = chunks.makeAsyncIterator()
        let firstChunk = await receivedChunks.next()
        #expect(firstChunk == "ready")
        try await Task.sleep(for: .seconds(1))
        let clock = ContinuousClock()
        let cancelledAt = clock.now

        reading.cancel()

        await #expect(throws: ProcessRunnerError.cancelled) {
            _ = try await reading.value
        }
        #expect(cancelledAt.duration(to: clock.now) < .seconds(10))
    }

    @Test func theDrainLimitIsOffByDefault() {
        let request = ProcessRequest(executableURL: Self.shell, timeout: 1, idleTimeout: 1)

        #expect(request.outputDrainLimit == nil)
    }

    /// Its own concurrency gate, so a run held open by a background job never queues behind,
    /// or holds up, the shared process-wide limiter other suites use.
    private static func isolatedRunner() -> ProcessRunner {
        ProcessRunner(limiter: ProcessLimiter(limit: 2))
    }

    private static func fileAppears(at url: URL, within limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
