import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Log correlation within an update")
struct DiagnosticLogCorrelationTests {
    @Test func anErrorKeepsItsContextAndIsPersistedBeforeReturning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticTraceStore(directory: directory)
        let run = DiagnosticRun(trigger: "manual", subjects: ["discord"], store: store)
        UpdateDiagnostics.$current.withValue(run) {
            WegaLog.error(.homebrew, "Update failed", detail: LogDetail(
                command: "brew upgrade --cask discord", exitCode: 7,
                stderr: "Permission denied\ntoken=example-sensitive-token", subject: "discord"
            ))
        }
        let reopened = DiagnosticTraceStore(directory: directory)
        let event = try #require(reopened.events(runID: run.id).first { $0.event == "log" })
        #expect(event.fields["message"] == "Update failed")
        #expect(event.fields["level"] == "error")
        #expect(event.fields["detail.exit"] == "7")
        #expect(event.fields["detail.subject"] == "discord")
        #expect(event.output?.contains("Permission denied") == true)
        #expect(event.output?.contains("example-sensitive-token") == false)
        run.finish()
    }
}
