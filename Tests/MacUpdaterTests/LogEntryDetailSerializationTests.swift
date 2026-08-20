import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LogEntry detail serialization")
struct LogEntryDetailSerializationTests {

    private func entry(_ message: String, detail: LogDetail? = nil) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 1_770_000_000),
                 level: .error, category: .homebrew, message: message, detail: detail)
    }

    @Test func anEntryWithoutADetailSerialisesExactlyAsBefore() {
        let plain = entry("foo się wywalił")
        #expect(plain.fileText == plain.fileLine)
        #expect(plain.fileText.contains("\n") == false)
    }

    @Test func anEntryWithADetailAppendsContinuationLines() {
        let detailed = entry("foo się wywalił",
                             detail: LogDetail(command: "brew upgrade --cask foo", exitCode: 1, stderr: "boom"))
        let lines = detailed.fileText.components(separatedBy: "\n")
        #expect(lines.first == detailed.fileLine)
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix(LogDetail.continuationPrefix) })
    }

    @Test func parseLogRoundTripsAnEntryWithItsDetail() {
        let original = entry("foo się wywalił",
                             detail: LogDetail(command: "brew upgrade --cask foo", exitCode: 1, stderr: "boom"))
        let parsed = LogEntry.parseLog(original.fileText)
        #expect(parsed.count == 1)
        #expect(parsed.first?.message == original.message)
        #expect(parsed.first?.detail == original.detail)
    }

    @Test func theLegacySingleLineParserStillIgnoresContinuationLines() {
        // Gwarancja wstecz: starsza wersja aplikacji czytająca nowszy plik gubi detal,
        // ale nie tworzy z niego fałszywego wpisu i nie wywraca się.
        #expect(LogEntry.parse("\t| command: brew upgrade --cask foo") == nil)
    }

    @Test func orphanContinuationLinesAtTheStartOfATailAreDropped() {
        // `loadFromFile` bierze ogon pliku, który może zaczynać się w środku wpisu.
        let text = ["\t| exit: 1", "\t| ---", "\t| boom", entry("kolejny wpis").fileLine]
            .joined(separator: "\n")
        let parsed = LogEntry.parseLog(text)
        #expect(parsed.count == 1)
        #expect(parsed.first?.message == "kolejny wpis")
        #expect(parsed.first?.detail == nil, "sieroce linie nie mogą przykleić się do następnego wpisu")
    }

    @MainActor
    @Test func aStoreRoundTripsADetailThroughTheRealFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-logdetail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LogStore(directory: directory)
        let detail = LogDetail(command: "brew upgrade --cask foo", exitCode: 1, stderr: "boom")
        store.append(entry("foo się wywalił", detail: detail))
        store.flushForTests()

        let reloaded = LogStore(directory: directory)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.first?.detail == detail)
    }
}
