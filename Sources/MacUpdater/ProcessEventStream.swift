import Foundation
import MacUpdaterCore

/// ARCH-07a — the one home of the brew/npm event-streaming loop and its log-buffer cap.
///
/// Six upgrade/uninstall paths — the foreground cask installer, `runBrewUpgrade`,
/// `runNpmUpgrade`, the migration cask installer, the duplicate remover and the
/// background updater — each used to copy the same
/// `for try await event in stream { switch event … }` loop verbatim. The copies had
/// drifted apart on the one number that matters: the live log kept the last 200 lines
/// in the migration paths, 500 in the foreground upgrade paths, and grew unbounded in
/// the paths that only appended without trimming. This helper folds them onto a single
/// loop with a single cap, so the loop exists once and the buffer limit is defined in
/// one place.
enum ProcessEventStream {
    /// How many lines a streamed brew/npm log keeps in memory. One number, one place —
    /// before ARCH-07a each copied loop carried its own (200, 500 or no cap at all).
    static let logLineLimit = 500

    /// Turn a raw stdout/stderr chunk into the non-empty log lines it contributes.
    ///
    /// `trimmingWhitespace` mirrors the two shapes the copied loops used: the brew/npm
    /// upgrade log kept raw non-empty lines, while the duplicate-removal log trimmed
    /// each line first.
    static func lines(from chunk: String, trimmingWhitespace: Bool = false) -> [String] {
        chunk
            .components(separatedBy: "\n")
            .map { trimmingWhitespace ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : $0 }
            .filter { !$0.isEmpty }
    }

    /// Append `lines` to `log` and return it trimmed to the newest `logLineLimit`
    /// entries, dropping the oldest. The single definition of the streamed-log buffer
    /// cap — value-returning so callers can assign straight back into their `@Published`
    /// log without an `inout` through the property wrapper.
    static func appendingCapped(_ lines: [String], to log: [String]) -> [String] {
        guard !lines.isEmpty else { return log }
        var result = log
        result.append(contentsOf: lines)
        if result.count > logLineLimit {
            result.removeFirst(result.count - logLineLimit)
        }
        return result
    }

    /// Drive a brew/npm event stream to completion, handing every stdout/stderr chunk to
    /// `onChunk` and returning the process exit code. The single copy of the streaming
    /// loop the six call sites now share.
    ///
    /// Runs on the main actor because every caller mutates `@Published` log state from
    /// inside `onChunk`, exactly as the inlined loops did.
    @MainActor
    static func drain(
        _ stream: AsyncThrowingStream<ProcessOutputEvent, Error>,
        onChunk: (String) -> Void
    ) async throws -> Int32 {
        var exitCode: Int32 = 0
        for try await event in stream {
            switch event {
            case .stdout(let chunk), .stderr(let chunk):
                onChunk(chunk)
            case .finished(let result):
                exitCode = result.exitCode
            }
        }
        return exitCode
    }
}
