import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Diagnostics export outcome") @MainActor
struct DiagnosticsExportOutcomeTests {
    private let payload: @MainActor () async -> DiagnosticsExportPayload = {
        DiagnosticsExportPayload(data: Data("zip".utf8), suggestedFileName: "wega.zip")
    }

    /// A reference the panel stub reads, so one controller can see a save and then a cancel.
    @MainActor final class Destination {
        var url: URL?
        init(_ url: URL?) { self.url = url }
    }

    @Test func aSavedExportOffersFinder() async {
        let url = URL(fileURLWithPath: "/tmp/wega-\(UUID().uuidString).zip")
        let c = DiagnosticsExportController(makePayload: payload, chooseDestination: { _ in url }, write: { _, _ in })
        await c.export()
        #expect(c.outcome == .saved(url))
        #expect(c.lastExportURL == url)
        #expect(DiagnosticsExportStatusCopy.text(for: c.outcome) == tr("Zapisano diagnostykę."))
    }

    @Test func aFailedWriteSaysWhatToDoNext() async {
        struct Full: LocalizedError { var errorDescription: String? { "disk full" } }
        let c = DiagnosticsExportController(makePayload: payload, chooseDestination: { _ in URL(fileURLWithPath: "/tmp/x.zip") },
                                            write: { _, _ in throw Full() })
        await c.export()
        #expect(c.outcome == .failed("disk full"))
        withLanguage(.en) {
            #expect(DiagnosticsExportStatusCopy.text(for: c.outcome) == "Couldn't save diagnostics: disk full. Try again.")
        }
    }

    @Test func aCancelledPanelIsNeitherSuccessNorFailure() async {
        let destination = Destination(URL(fileURLWithPath: "/tmp/first.zip"))
        let c = DiagnosticsExportController(makePayload: payload, chooseDestination: { _ in destination.url }, write: { _, _ in })
        await c.export()
        destination.url = nil
        await c.export()
        #expect(c.outcome == .cancelled)
        #expect(c.lastExportURL == nil, "a cancelled export clears the previous result")
        #expect(DiagnosticsExportStatusCopy.text(for: .cancelled) == nil)
    }

    @Test func theReportButtonSaysWhatItOpens() {
        #expect(BugReportCopy.openTitle(for: .email(address: "a@b.c")) == tr("Otwórz szkic e-maila"))
        let issue = BugReportChannel.gitHubIssue(endpoint: URL(string: "https://github.com/o/r/issues/new")!)
        #expect(BugReportCopy.openTitle(for: issue) == tr("Otwórz zgłoszenie na GitHubie"))
        withLanguage(.en) {
            #expect(BugReportCopy.openTitle(for: .email(address: "a@b.c")) == "Open Email Draft")
            #expect(BugReportCopy.openTitle(for: issue) == "Open Issue on GitHub")
        }
        #expect(BugReportCopy.entriesHint(entryCount: 0) == tr("Zaznacz wpisy w logu, jeśli chcesz je dołączyć."))
        #expect(BugReportCopy.entriesHint(entryCount: 2) == nil)
    }

    @Test func everyReportEntryPointOpensTheSameSheet() throws {
        let logs = try source("Sources/MacUpdater/LogsView.swift")
        #expect(logs.contains("DiagnosticsExportStatusRow(controller: diagnosticsExport)"))
        let info = try source("Sources/MacUpdater/InfoView.swift")
        #expect(!info.contains("Link(tr(\"Zgłoś błąd\"), destination:"))
        #expect(info.contains("BugReportController(entries: [])"))
        #expect(info.contains("DiagnosticsExportStatusRow(controller: diagnosticsExport)"))
        let sheet = try source("Sources/MacUpdater/BugReportSheet.swift")
        #expect(!sheet.contains("tr(\"Wyślij zgłoszenie\")"))
        #expect(sheet.contains("BugReportCopy.openTitle(for: selectedChannel)"))
        #expect(sheet.contains("tr(\"Wykryte dane wrażliwe zastąpiłam. Sprawdź podgląd przed wysłaniem.\")"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
