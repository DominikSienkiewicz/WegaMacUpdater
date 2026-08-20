import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("ProcessRunner failure detail")
struct ProcessRunnerDetailTests {

    /// Gwarancja przypięta w źródle: cofnięcie tej zmiany oznacza, że każda awaria
    /// procesu znów mówi tylko „exited 1", bez powodu.
    @Test func nonZeroExitAttachesCommandAndStderrToTheLogEntry() throws {
        let source = try Self.source("Sources/MacUpdaterCore/ProcessRunner.swift")
        #expect(source.contains("detail: LogDetail("))
        #expect(source.contains("stderr: result.stderr"))
        #expect(source.contains("exitCode: result.exitCode"))
    }

    @Test func aFailedRunCarriesStderrInTheDetail() async throws {
        let result = try await ProcessRunner().run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo boom >&2; exit 3"],
            environment: [:],
            inheritParentEnvironment: false,
            timeouts: .quick
        ))
        #expect(result.exitCode == 3)
        let detail = try #require(LogDetail(
            command: "sh", exitCode: result.exitCode, stderr: result.stderr
        ))
        #expect(detail.output?.contains("boom") == true)
        #expect(detail.fields.contains(LogDetail.Field(key: "exit", value: "3")))
    }

    /// Closes the gap the other two tests leave open: the source-inspection test only
    /// pins the call-site text, and `aFailedRunCarriesStderrInTheDetail` builds its own
    /// `LogDetail` rather than reading the one `ProcessRunner` actually logs. This test
    /// runs a real failing subprocess and reads back the `LogStore` entry that
    /// `WegaLog.debug(..., detail:)` produced, end to end.
    ///
    /// Exit code 47 is arbitrary but distinct from other subprocess tests in this target
    /// (e.g. `exit 3` elsewhere) — irrelevant to correctness, since the entry is located
    /// by a unique marker in `detail.output` rather than by exit code, but it keeps the
    /// assertion on the `"exit"` field unambiguous if logs from other tests interleave.
    @Test func nonZeroExitLogsAnEntryCarryingTheStderrThroughWegaLog() async throws {
        let marker = UUID().uuidString
        let exitCode: Int32 = 47
        _ = try await ProcessRunner().run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo \(marker) 1>&2; exit \(exitCode)"],
            environment: [:],
            inheritParentEnvironment: false,
            timeouts: .quick
        ))

        // WegaLog appends from an unstructured `Task { @MainActor in ... }`, so the entry
        // is not necessarily there yet when `run(...)` returns — poll instead of asserting
        // immediately, and never with a fixed sleep.
        let entry = try await Self.findEntry(withOutputContaining: marker, timeout: 2.0)

        #expect(entry.category == .process)
        // Pins that a non-zero exit stays at debug rather than escalating to warning/error.
        #expect(entry.level == .debug)
        #expect(entry.detail?.output?.contains(marker) == true)
        #expect(entry.detail?.fields.contains(LogDetail.Field(key: "exit", value: String(exitCode))) == true)
        #expect(entry.detail?.fields.first(where: { $0.key == "command" })?.value.contains("sh") == true)
    }

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Polls `LogStore.shared` on the main actor for the entry whose `detail.output`
    /// carries `marker`. Never asserts immediately and never sleeps for a fixed duration —
    /// the log append happens on a detached `@MainActor` task, so the timing is not
    /// deterministic. Does not call `LogStore.shared.clear()`: the store is a shared
    /// singleton other tests also append to.
    private static func findEntry(withOutputContaining marker: String, timeout: Double) async throws -> LogEntry {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let entry = await MainActor.run {
                LogStore.shared.entries.first { $0.detail?.output?.contains(marker) == true }
            }
            if let entry {
                return entry
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        throw TestError.entryNeverArrived(marker: marker)
    }

    private enum TestError: Error {
        case entryNeverArrived(marker: String)
    }
}
