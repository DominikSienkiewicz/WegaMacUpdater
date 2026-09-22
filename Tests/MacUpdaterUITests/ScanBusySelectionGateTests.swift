import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// The quiet launch refresh leaves the previous result on screen and scans underneath it
/// (`ScanStore.isRefreshing`). Everything that made that bearable — the list keeps the window,
/// the header names the phase — also made it invisible: the rows stayed lit, the checkboxes
/// stayed live, and `Zaktualizuj wybrane` stayed enabled.
///
/// The last of those is the defect these pin. A batch update started during a refresh runs
/// against the list the refresh is in the middle of replacing, so the user approves one set of
/// packages and the app installs whatever the scan has settled on by the time the dialog is
/// confirmed. Against the unfixed `UpdateView` both assertions below fail: the button's only
/// guards were `scan.updating` and an empty selection, and the ⌘⏎ menu action repeated them.
@Suite("Scan busy selection gate")
@MainActor
struct ScanBusySelectionGateTests {
    @Test func theUpdatesScreenRefusesToStartABatchWhileAScanIsRunning() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))

        #expect(view.contains("ScanSelectionGate.allowsUpdateRun("),
                "the batch button must ask one gate whether an update may start at all")
        #expect(!view.contains(".disabled(scan.updating || updateTargets.isEmpty)"),
                "the old guard ignored a running scan — a batch could be started mid-refresh")
    }

    @Test func theKeyboardShortcutIsHeldToTheSameGate() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        let shortcut = try #require(
            view.range(of: "runUpdateAction").map { String(view[$0.lowerBound...].prefix(400)) },
            "UpdateView must still publish the ⌘⏎ action"
        )

        #expect(shortcut.contains("ScanSelectionGate.allowsUpdateRun("),
                "⌘⏎ must not be a way around the button's guard")
    }

    /// The visible half of the same rule: while the scan runs the list says so and stops
    /// taking selections, instead of looking exactly like a finished result.
    @Test func theListSaysItIsBusyAndStopsTakingSelections() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))

        #expect(view.contains("ScanBusyOverlay("),
                "a running scan must be visible over the rows it is about to replace")
        #expect(view.contains("ScanSelectionGate.allowsSelection("),
                "the list must be gated on the same flag the overlay is shown for")
    }

    // MARK: - Helpers

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(path), encoding: .utf8)
    }

    private func executableSource(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
