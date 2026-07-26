import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// ARCH-07a — the shared brew/npm event-streaming helper. These lock in the single
/// behaviour the six copied loops now share: one buffer cap defined in one place, one
/// line-splitting rule, one loop that forwards each chunk and returns the exit code.
@Suite("Process event stream helper")
struct ProcessEventStreamTests {
    @Test func bufferLimitIsTheSingleSourceOfTruth() {
        #expect(ProcessEventStream.logLineLimit == 500)
    }

    @Test func appendingCappedKeepsOnlyTheNewestUpToTheLimit() {
        let existing = (0..<ProcessEventStream.logLineLimit).map { "line\($0)" }
        let result = ProcessEventStream.appendingCapped(["new-a", "new-b"], to: existing)

        #expect(result.count == ProcessEventStream.logLineLimit)
        #expect(result.last == "new-b")
        #expect(result.first == "line2") // the two oldest lines were dropped to make room
    }

    @Test func appendingCappedLeavesShortLogsAndEmptyInputUntouched() {
        #expect(ProcessEventStream.appendingCapped(["b"], to: ["a"]) == ["a", "b"])
        #expect(ProcessEventStream.appendingCapped([], to: ["a"]) == ["a"])
    }

    @Test func linesSplitsAndFiltersEmptyKeepingRawTextByDefault() {
        #expect(ProcessEventStream.lines(from: "one\n\ntwo\n") == ["one", "two"])
        #expect(ProcessEventStream.lines(from: "  spaced  \n x ") == ["  spaced  ", " x "])
    }

    @Test func linesTrimsEachLineWhenAsked() {
        #expect(
            ProcessEventStream.lines(from: "  one  \n\t two \n   ", trimmingWhitespace: true) == ["one", "two"]
        )
    }

    @MainActor
    @Test func drainForwardsEveryChunkAndReturnsTheFinishedExitCode() async throws {
        var collected: [String] = []
        let stream = AsyncThrowingStream<ProcessOutputEvent, Error> { continuation in
            continuation.yield(.stdout("first\n"))
            continuation.yield(.stderr("second"))
            continuation.yield(.finished(ProcessResult(exitCode: 7, stdout: "", stderr: "")))
            continuation.finish()
        }

        let exitCode = try await ProcessEventStream.drain(stream) { collected.append($0) }

        #expect(exitCode == 7)
        #expect(collected == ["first\n", "second"])
    }

    @MainActor
    @Test func drainRethrowsAStreamFailure() async {
        struct Boom: Error {}
        let stream = AsyncThrowingStream<ProcessOutputEvent, Error> { continuation in
            continuation.yield(.stdout("partial"))
            continuation.finish(throwing: Boom())
        }

        await #expect(throws: Boom.self) {
            _ = try await ProcessEventStream.drain(stream) { _ in }
        }
    }
}
