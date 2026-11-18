import Foundation
import Testing
@testable import WegaMacUpdater

/// UX-20 — a running update put a dialog-like card in the middle of the screen while the action
/// bar it came from disappeared under the material. The run now takes the action bar's place
/// and shape at the bottom: the same chrome, carrying the progress, the log and the stop. It
/// stays part of `UpdateRunOverlay`, the one live layer above the disabled screen (REL-12), so
/// the stop button can never be greyed out with what it covers.
@Suite("Update run bar")
@MainActor
struct UpdateRunBarTests {
    @Test func theStopButtonSaysWhenItStops() {
        #expect(UpdateRunCopy.stopLabel(isStopping: false) == tr("Zatrzymaj po bieżącym"))
        #expect(UpdateRunCopy.stopLabel(isStopping: true) == tr("Przerywam…"))
    }

    @Test func theNoteExplainsTheLockAndThenTheStop() {
        #expect(UpdateRunCopy.note(isStopping: false)
                == tr("Do końca aktualizacji lista jest zablokowana. Możesz ją przerwać — bieżący pakiet dokończę, kolejnych nie zacznę."))
        #expect(UpdateRunCopy.note(isStopping: true)
                == tr("Przerywam po bieżącym pakiecie — kolejne nie wystartują."))
    }

    @Test func theRunTakesTheActionBarsPlaceAndShape() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let overlay = try source("Sources/MacUpdater/UpdateRunOverlay.swift")
        let lower = try #require(view.range(of: "private var actionBar: some View")?.lowerBound)
        let upper = try #require(view.range(of: "private var listColumn: some View")?.lowerBound)
        let actionBar = view[lower..<upper]

        #expect(actionBar.contains(".wegaBottomBar()"), "the action bar draws through the shared chrome")
        #expect(overlay.contains(".wegaBottomBar()"), "and so does the run that replaces it")
        #expect(!overlay.contains(".frame(maxWidth: 560)"), "no dialog card in the middle of the screen")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
