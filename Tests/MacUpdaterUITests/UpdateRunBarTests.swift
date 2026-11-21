import Foundation
import Testing
@testable import WegaMacUpdater

/// UX-20 — a running update put a dialog-like card in the middle of the screen while the action
/// bar it came from disappeared under the material; the run then took a bar at the bottom of
/// the list. C2 stage 3 moved it into the band above the list (`UpdateRunInBandTests`), so no
/// bottom bar is left. The stop keeps REL-12's words before and after it is requested.
@Suite("Update run bar")
@MainActor
struct UpdateRunBarTests {
    @Test func theStopButtonSaysWhenItStops() {
        #expect(UpdateRunCopy.stopLabel(isStopping: false) == tr("Zatrzymaj po rozpoczętych instalacjach"))
        #expect(UpdateRunCopy.stopLabel(isStopping: true) == tr("Kończę rozpoczęte instalacje, nowych nie zaczynam"))
    }

    @Test func theNoteExplainsTheLockAndThenTheStop() {
        #expect(UpdateRunCopy.note(isStopping: false)
                == tr("Do końca aktualizacji lista jest zablokowana. Możesz ją przerwać — bieżący pakiet dokończę, kolejnych nie zacznę."))
        #expect(UpdateRunCopy.note(isStopping: true)
                == tr("Przerywam po bieżącym pakiecie — kolejne nie wystartują."))
    }

    @Test func theRunHasNoBottomBarLeft() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")

        #expect(!view.contains("struct WegaBottomBar"), "the run moved into the band; nothing uses the bottom chrome")
        #expect(!view.contains("wegaBottomBar()"))
        #expect(!view.contains("private var actionBar"), "the action bar it once matched is gone")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
