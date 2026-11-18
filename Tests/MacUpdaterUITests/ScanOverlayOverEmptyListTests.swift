import Foundation
import Testing
@testable import WegaMacUpdater

/// The in-place scan's overlay stands the rows of the list down. Over an empty state there are
/// no rows to stand down, yet its material covered the column anyway: the big empty-state Wega
/// ("Wszystko aktualne", or the one after a scan that heard from no source) and her tricks sat
/// behind milky glass for the whole scan. The overlay now covers rows only.
@Suite("Scan overlay over an empty list")
struct ScanOverlayOverEmptyListTests {
    @Test func theOverlayCoversRowsOnly() {
        #expect(ScanSelectionGate.coversList(isRefreshing: true, showsRows: true))
        #expect(!ScanSelectionGate.coversList(isRefreshing: true, showsRows: false),
                "an empty state has nothing to stand down; Wega stays clear")
        #expect(!ScanSelectionGate.coversList(isRefreshing: false, showsRows: true))
    }

    @Test func theUpdatesScreenAsksBeforeCoveringTheList() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/MacUpdater/UpdateView.swift"), encoding: .utf8
        )

        #expect(view.contains("ScanSelectionGate.coversList(isRefreshing: scan.isRefreshing, showsRows: showsRows)"))
        #expect(view.contains("private var showsRows: Bool"), "one answer for the list and for its overlay")
    }
}
