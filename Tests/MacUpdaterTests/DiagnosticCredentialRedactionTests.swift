import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Credentials in diagnostic URLs")
struct DiagnosticCredentialRedactionTests {
    @Test func URLUserInformationIsRemovedBeforeTracePersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticTraceStore(directory: directory)
        let run = DiagnosticRun(trigger: "test", subjects: [], store: store)
        let url = "https://private-login:private-passphrase@example.test/releases?token=query-secret"
        run.record("example", fields: ["url": url], output: "Download failed: \(url)\n")
        run.finish()
        let event = try #require(store.events(runID: run.id).first { $0.event == "example" })
        for text in [event.fields["url"] ?? "", event.output ?? ""] {
            #expect(!text.contains("private-login"))
            #expect(!text.contains("private-passphrase"))
            #expect(!text.contains("query-secret"))
            #expect(text.contains("example.test"))
        }
    }
}
