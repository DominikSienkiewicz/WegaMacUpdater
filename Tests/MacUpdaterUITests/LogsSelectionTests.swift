import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Logs selection")
struct LogsSelectionTests {

    private func entry(_ message: String) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 1_770_000_000), level: .error,
                 category: .homebrew, message: message)
    }

    @Test func selectionIsPrunedToTheVisibleEntries() {
        let visible = [entry("a"), entry("b")]
        let hidden = entry("c")
        // Bez przycięcia dałoby się zaznaczyć wpis, zmienić filtr i wysłać coś,
        // czego użytkownik już nie widzi.
        #expect(LogSelection.pruned([visible[0].id, hidden.id], toVisible: visible) == [visible[0].id])
    }

    @Test func anEmptySelectionStaysEmpty() {
        #expect(LogSelection.pruned([], toVisible: [entry("a")]).isEmpty)
    }

    @Test func theReportButtonIsGatedOnANonEmptySelection() throws {
        let source = try Self.source("Sources/MacUpdater/LogsView.swift")
        #expect(source.contains(".disabled(selection.isEmpty)"))
        #expect(source.contains("tr(\"Zgłoś błąd…\")"))
    }

    @Test func theListCarriesASelectionBinding() throws {
        let source = try Self.source("Sources/MacUpdater/LogsView.swift")
        #expect(source.contains("List(visible, selection: $selection)"))
    }

    @Test func anEntryWithADetailRendersADisclosure() throws {
        let source = try Self.source("Sources/MacUpdater/LogsView.swift")
        #expect(source.contains("if let detail = entry.detail"))
        // UX-02: bare `DisclosureGroup`'s label isn't a click target — the app's own guard
        // (`UX02ActionableControlsTests.noDisclosureGroupSurvivesInTheAppTarget`) bans it
        // project-wide, so this uses `WegaDisclosure` instead.
        #expect(source.contains("WegaDisclosure"))
    }

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
