import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// UXP-01 — a zero after a failed or partial check must never read as "up to date".
@Suite("Menu bar status") @MainActor
struct MenuBarStatusPresentationTests {
    @Test func zeroAfterAFailedCheckIsNotUpToDate() {
        let p = MenuBarStatusPresentation(count: 0, isChecking: false, failed: true, incomplete: true, lastCheck: .now)
        #expect(p.accessibilityLabel == tr("Nie udało się sprawdzić"))
        #expect(p.statusText == tr("Nie udało się sprawdzić"))
    }

    @Test func updatesFromAnIncompleteCheckSayItIsIncomplete() {
        let p = MenuBarStatusPresentation(count: 3, isChecking: false, failed: false, incomplete: true, lastCheck: .now)
        #expect(p.statusText == trp("%@ aktualizacji dostępnych", 3) + " · " + tr("sprawdzanie niepełne"))
        #expect(p.accessibilityLabel == p.statusText)
    }

    @Test func onlyACompleteZeroIsUpToDate() {
        #expect(MenuBarStatusPresentation(count: 0, isChecking: false, failed: false, incomplete: false, lastCheck: .now)
            .accessibilityLabel == tr("Wszystko aktualne"))
        #expect(MenuBarStatusPresentation(count: 0, isChecking: false, failed: false, incomplete: false, lastCheck: nil)
            .statusText == tr("Jeszcze nie sprawdzano"))
        #expect(MenuBarStatusPresentation(count: 0, isChecking: true, failed: false, incomplete: false, lastCheck: nil)
            .accessibilityLabel == tr("Sprawdzam aktualizacje…"))
    }

    /// A cancelled scan lands on `.results` without `.finished`; it must earn no comment at all.
    @Test func aCancelledScanTriggersNoQuip() throws {
        let file = #filePath
        let root = URL(filePath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "Sources/MacUpdater/DetailColumn.swift"), encoding: .utf8)
        #expect(text.contains("scan.progress == .finished"))
    }
}
