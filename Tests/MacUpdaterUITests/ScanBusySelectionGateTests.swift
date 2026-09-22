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

    /// The ring reports the phase the scan is genuinely in, and declines to report one when
    /// the scan has not named it — including after a finished run leaves `.finished` standing,
    /// which would otherwise open the next refresh on a full ring.
    @Test func theOverlayClaimsNoPositionTheScanHasNotTaken() {
        let brew = ScanBusyPresentation(progress: .running(.brew))
        #expect(brew.fraction == 0)
        #expect(brew.percentLabel == "0%")
        #expect(brew.phaseLabel == "brew outdated")

        let npm = ScanBusyPresentation(progress: .running(.npm))
        #expect(npm.percentLabel == "50%")
        #expect(npm.accessibilityValue == "npm outdated -g — 50%")

        for progress: ScanProgress? in [nil, .finished, .cancelled(at: .mas)] {
            let presentation = ScanBusyPresentation(progress: progress)
            #expect(presentation.fraction == nil, "\(String(describing: progress)) is not a running phase")
            #expect(presentation.percentLabel == nil)
            #expect(presentation.phaseLabel == nil)
        }
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
