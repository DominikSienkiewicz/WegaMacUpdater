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

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
