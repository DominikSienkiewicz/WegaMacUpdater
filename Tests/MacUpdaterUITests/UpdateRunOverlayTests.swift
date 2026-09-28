import Foundation
import Testing
@testable import WegaMacUpdater

/// While a batch installs, the Updates screen used to stay fully live: row checkboxes,
/// "Zaznacz wszystko", ignore/pin/skip, the manual "install" buttons, the banner's reinstall
/// action and the stale-cask card. Each either edits a selection the run already committed
/// to or starts a second package-manager operation mid-run. The list was only ever disabled
/// for a refresh (`allowsSelection(isRefreshing:)`), never for an update.
///
/// Against the unfixed `UpdateView` every source assertion below fails: there was no
/// `allowsScreenInteraction`, no `UpdateRunOverlay`, and the stop button sat in the header.
@Suite("Update run overlay")
@MainActor
struct UpdateRunOverlayTests {
    @Test func theScreenIsInertForTheWholeRun() {
        #expect(ScanSelectionGate.allowsScreenInteraction(isUpdating: false))
        #expect(!ScanSelectionGate.allowsScreenInteraction(isUpdating: true),
                "a running update owns the screen until it lands")
    }

    @Test func theUpdatesScreenDisablesEverythingBelowTheHeaderWhileUpdating() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))

        #expect(view.contains(".disabled(!ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating))"),
                "rows, banner, plan preview, stale-cask card and manual installs must be inert during a run")
        #expect(view.contains(".accessibilityHidden(scan.updating)"),
                "VoiceOver must not reach the controls the overlay covers")
    }

    @Test func theRunIsDrawnOverTheScreenWithItsStopButton() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        let overlay = executableSource(try source("Sources/MacUpdater/UpdateRunOverlay.swift"))

        #expect(view.contains("if scan.updating {\n                        updateRunOverlay"),
                "the overlay appears exactly while an update runs")
        #expect(view.contains("onCancel:   { scan.cancelUpdate() }"),
                "and its stop button is wired to the run's cooperative cancel")
        #expect(overlay.contains(".background(.regularMaterial)"),
                "the overlay covers the screen it stands down")
        #expect(overlay.contains(".disabled(isStopping)"),
                "a stop already requested cannot be requested twice")
    }

    /// The overlay is applied after `.disabled`, so it is not itself disabled. Were the order
    /// reversed, the stop button would be greyed out along with everything it covers.
    @Test func theStopButtonStaysLiveAboveTheDisabledScreen() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        let disabled = try #require(view.range(of: "allowsScreenInteraction(isUpdating:"))
        let overlay = try #require(view.range(of: "updateRunOverlay\n"))

        #expect(disabled.lowerBound < overlay.lowerBound)
    }

    /// The stop button used to sit in the header next to "Zaktualizuj wybrane". Two stop
    /// buttons for one run is one too many.
    @Test func theHeaderNoLongerCarriesASecondStopButton() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))

        #expect(view.components(separatedBy: "scan.cancelUpdate()").count == 2,
                "exactly one call site: the overlay")
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
