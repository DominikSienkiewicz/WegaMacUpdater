import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UX-16 — "Wszystkie / Aplikacje / Narzędzia CLI / Poprawki bezp." were four sidebar rows
/// for one list, so the sidebar counted the same updates twice and mixed "where am I" with
/// "what am I filtering". The sidebar now has one Updates row and the filter is a scope bar
/// above the list.
@Suite("Update scope bar")
@MainActor
struct UpdateScopeBarTests {
    @Test func theSidebarShowsOneUpdatesRowWhateverTheFilter() {
        #expect(SidebarSelection.updates(.apps).sidebarRow == .updates(.all))
        #expect(SidebarSelection.updates(.security).sidebarRow == .updates(.all))
        #expect(SidebarSelection.logs.sidebarRow == .logs)
    }

    /// Clicking the Updates row while already on Updates must not throw the chosen scope away;
    /// arriving from elsewhere starts on the whole list.
    @Test func pickingTheUpdatesRowKeepsTheScopeOnlyWhenAlreadyThere() {
        #expect(SidebarSelection.updates(.cli).applyingSidebarPick(.updates(.all)) == .updates(.cli))
        #expect(SidebarSelection.logs.applyingSidebarPick(.updates(.all)) == .updates(.all))
        #expect(SidebarSelection.updates(.cli).applyingSidebarPick(.inventory) == .inventory)
    }

    @Test func theTitleNamesTheScreenNotTheFilter() {
        for filter in [UpdateFilter.all, .apps, .cli, .security] {
            #expect(SidebarSelection.updates(filter).label == tr("Aktualizacje"))
        }
    }

    @Test func eachScopeCountsItsOwnRows() {
        let counts = UpdateScopeCounts(apps: 7, cli: 5, security: 2)
        let options = UpdateScopeOption.options(counts: counts)

        #expect(options.map(\.filter) == [.all, .apps, .cli, .security])
        #expect(options.map(\.count) == [12, 7, 5, 2])
        #expect(options.map(\.title) == [tr("Wszystkie"), tr("Aplikacje"), tr("Narzędzia CLI"), tr("Poprawki bezp.")])
    }

    @Test func theFilterRowsLeaveTheSidebarForTheScopeBar() throws {
        let sidebar = try source("Sources/MacUpdater/SidebarList.swift")
        let update = try source("Sources/MacUpdater/UpdateView.swift")

        for row in ["row(.updates(.apps)", "row(.updates(.cli)", "row(.updates(.security)"] {
            #expect(!sidebar.contains(row), "\(row) is a filter, not a destination")
        }
        #expect(update.contains("UpdateScopeBar("))
    }

    /// The gear duplicated ⌘, and the app menu; the inspector toggle stays put but disappears
    /// outside Updates instead of sitting there dimmed. Its geometry never changes: a toolbar
    /// item whose width changes can invalidate the window's safe area.
    @Test func theToolbarDropsTheGearAndHidesTheInspectorToggleElsewhere() throws {
        let content = try source("Sources/MacUpdater/ContentView.swift")

        #expect(!content.contains("SettingsLink"))
        #expect(content.contains(".opacity(selection.tab == .update ? 1 : 0)"))
        #expect(content.contains(#"Image(systemName: "globe")"#), "the language menu stays")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
