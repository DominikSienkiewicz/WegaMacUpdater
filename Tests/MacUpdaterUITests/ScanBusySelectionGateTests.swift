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
        #expect(view.contains("isRefreshing: scan.isRefreshing"),
                "and that gate must be told about the scan running underneath the list")
        #expect(!view.contains(".disabled(scan.updating || updateTargets.isEmpty)"),
                "the old guard ignored a running scan — a batch could be started mid-refresh")
    }

    /// ⌘⏎ reaches `requestUpdate()` without touching the button, so it needs the same answer
    /// rather than its own copy of the condition — which is how the two drifted apart before.
    @Test func theKeyboardShortcutIsHeldToTheSameGate() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        let shortcut = try #require(
            view.range(of: "runUpdateAction").map { String(view[$0.lowerBound...].prefix(400)) },
            "UpdateView must still publish the ⌘⏎ action"
        )

        #expect(shortcut.contains("allowsUpdateRun"),
                "⌘⏎ must not be a way around the button's guard")
        #expect(!shortcut.contains("!scan.updating && !updateTargets.isEmpty"),
                "⌘⏎ must not re-derive the condition it shares with the button")
        #expect(view.contains(".disabled(!allowsUpdateRun)"),
                "and the button must read the same property, not a second copy of the rule")
    }

    @Test func theGateRefusesEveryReasonAnUpdateCannotStart() {
        #expect(ScanSelectionGate.allowsUpdateRun(isRefreshing: false, isUpdating: false, hasTargets: true))
        #expect(!ScanSelectionGate.allowsUpdateRun(isRefreshing: true, isUpdating: false, hasTargets: true),
                "a running scan is replacing the very list the batch was picked from")
        #expect(!ScanSelectionGate.allowsUpdateRun(isRefreshing: false, isUpdating: true, hasTargets: true))
        #expect(!ScanSelectionGate.allowsUpdateRun(isRefreshing: false, isUpdating: false, hasTargets: false))

        #expect(ScanSelectionGate.allowsSelection(isRefreshing: false))
        #expect(!ScanSelectionGate.allowsSelection(isRefreshing: true))
    }

    @Test func selectAllInTheListHeaderFollowsBothGates() throws {
        #expect(ScanSelectionGate.allowsListSelection(isRefreshing: false, isUpdating: false))
        #expect(!ScanSelectionGate.allowsListSelection(isRefreshing: true, isUpdating: false),
                "a refresh is replacing the list the selection would be made against")
        #expect(!ScanSelectionGate.allowsListSelection(isRefreshing: false, isUpdating: true),
                "a running update owns the screen")
        #expect(!ScanSelectionGate.allowsListSelection(isRefreshing: true, isUpdating: true))

        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        #expect(view.contains(".disabled(!ScanSelectionGate.allowsListSelection(isRefreshing: scan.isRefreshing, isUpdating: scan.updating))"),
                "the header sits outside listColumn and screenBody, so select-all must carry both gates itself")
    }

    /// The bar reports the phase the scan is genuinely in, and declines to report one when the
    /// scan has not named it — including after a finished run leaves `.finished` standing,
    /// which would otherwise open the next refresh on a full bar.
    @Test func theOverlayClaimsNoPositionTheScanHasNotTaken() {
        let brew = ScanBusyPresentation(progress: .running(.brew))
        #expect(brew.fraction == 0)
        #expect(brew.phaseLabel == "brew outdated")
        #expect(brew.accessibilityValue == "brew outdated")

        let npm = ScanBusyPresentation(progress: .running(.npm))
        #expect(npm.fraction == 0.5)

        for progress: ScanProgress? in [nil, .finished, .cancelled(at: .mas)] {
            let presentation = ScanBusyPresentation(progress: progress)
            #expect(presentation.fraction == nil, "\(String(describing: progress)) is not a running phase")
            #expect(presentation.phaseLabel == nil)
        }
    }

    /// The scan wears one face, at one size. The full-screen scan and the overlay over the
    /// list used to report the identical thing; drawing the overlay's copy smaller, in a card,
    /// made them read as two different screens — Wega shrank and the binary stream was clipped
    /// mid-character by the card holding it. UXP-13 took the overlay away: a scan in place is
    /// told by the band and the list header, so the scene is drawn only by the first scan.
    ///
    /// `ScanProgressScene` still owns its sizing and its padding, and offers no knob for either,
    /// so the one screen that draws it cannot be given a different one.
    @Test func bothScanScreensDrawTheSameSceneAtTheSameSize() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        let overlay = executableSource(try source("Sources/MacUpdater/ScanBusyOverlay.swift"))

        #expect(view.contains("ScanProgressScene(progress: scan.progress, catalogRefreshing: scan.isRefreshingCatalog, accessory: scanRoundButton(style: .window))"),
                "the full-screen scan must draw the shared scene, with the round scan button as its stop")
        #expect(view.components(separatedBy: "ScanProgressScene(").count == 2,
                "only checkingView draws the scene; a scan in place draws none over the list")
        #expect(!overlay.contains("ScanProgressScene(progress: progress)"),
                "no overlay draws a copy of the scene over the list")
        #expect(!overlay.contains("enum Size"),
                "no size knob: that is what let the two screens diverge")
        #expect(!view.contains("SniffingScene("),
                "the scene is owned by ScanProgressScene — a second copy is how the two drifted")

        // The padding is part of the scene's geometry, so a caller cannot inset one screen
        // differently from the other. `checkingView` must therefore add none of its own.
        let checking = slice(view, from: "private var checkingView: some View {", to: "}")
        #expect(checking.contains("ScanProgressScene("),
                "sanity: the slice really found checkingView, so the next check is not vacuous")
        #expect(!checking.contains(".padding("),
                "sizing and padding belong to the scene, not to whoever places it")
    }

    /// The rows are stood down by `.disabled`; the one layer on them is the scanner (owner,
    /// 2026-11-22), which dims them halfway and blurs nothing, and no second dimming joins it.
    @Test func theOverlayStandsTheRowsDownWithoutASecondDimming() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        let overlay = executableSource(try source("Sources/MacUpdater/ScanBusyOverlay.swift"))
        let screen = slice(view, from: "private var screenBody: some View", to: "private var scopeBar: some View")

        #expect(screen.contains("listColumn"), "sanity: the slice really found screenBody")
        #expect(screen.components(separatedBy: ".overlay").count == 2, "only the scanner lies on the rows during a scan")
        #expect(screen.contains("{ ScanListVeil() }"))
        #expect(screen.contains(".disabled(!ScanSelectionGate.allowsSelection(isRefreshing: scan.isRefreshing))"),
                "the rows stay inert while the scan replaces them")
        #expect(!overlay.contains("struct ScanBusyOverlay"), "the scan's veil over the list is gone")
        #expect(!view.contains("dimmedListOpacity"),
                "and no separate list dimming took its place")
    }

    // MARK: - Helpers

    /// The text between `from` and the first `to` after it, `from` included — so an assertion
    /// about one declaration cannot accidentally match text belonging to another.
    private func slice(_ text: String, from: String, to: String) -> String {
        guard let start = text.range(of: from) else { return "" }
        let region = text[start.lowerBound...]
        guard let end = region.range(of: to) else { return String(region) }
        return String(region[..<end.upperBound])
    }

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
