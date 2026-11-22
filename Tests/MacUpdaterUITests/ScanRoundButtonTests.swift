import AppKit
import Foundation
import MacUpdaterCore
import SwiftUI
import Testing

@testable import WegaMacUpdater

/// Owner, 2026-11-22 (option B): the toolbar's „Sprawdź teraz”/„Anuluj” was hard to find, so the
/// scan action moved to a round button where the scan is reported: beside the band's big circle
/// (which since the same day stands over „Wszystko aktualne” too) and in the first scan's scene.
/// Do Homebrew and Cofnij get none; ⌘R and ⌘. still work everywhere.
@Suite("The round scan button") @MainActor
struct ScanRoundButtonTests {
    /// What `cancelScan()` can stop decides the stop; anything else is a start that the store's
    /// own gate may grey out. A check after a run or an undo cannot be cancelled, so it shows a
    /// greyed-out start, never a stop that does nothing.
    @Test func theStopFollowsWhatCanBeCancelled() {
        #expect(ScanRoundButtonState.resolve(canStartCheck: true, canCancelScan: false) == .start(enabled: true))
        #expect(ScanRoundButtonState.resolve(canStartCheck: false, canCancelScan: false) == .start(enabled: false))
        #expect(ScanRoundButtonState.resolve(canStartCheck: false, canCancelScan: true) == .cancel)
    }

    /// One size in every state and style, so nothing beside it moves when a scan starts or ends.
    @Test func theButtonIsOneSizeInEveryState() {
        for style in [ScanRoundButton.Style.band, .window] {
            for state in [ScanRoundButtonState.start(enabled: true), .start(enabled: false), .cancel] {
                let button = ScanRoundButton(state: state, style: style, onStart: {}, onCancel: {})
                #expect(NSHostingView(rootView: button).fittingSize == CGSize(width: 40, height: 40), "\(style) \(state)")
            }
        }
    }

    @Test func itSaysWhatItDoes() throws {
        withLanguage(.en) {
            #expect(tr("Sprawdź teraz") == "Check now")
            #expect(tr("Anuluj skan") == "Cancel Scan")
        }
        let text = try source("Sources/MacUpdater/ScanRoundButton.swift")
        #expect(text.contains(".accessibilityLabel(label)"))
        #expect(text.contains(".help(label)"))
        #expect(text.contains("tr(\"Sprawdź teraz\")") && text.contains("tr(\"Anuluj skan\")"))
        #expect(!text.contains("wegaHoney"), "honey is the update's colour, not the scan's")
    }

    /// Beside the big circle in the regular and compact band, above it in the narrow one; the
    /// circle stays the last thing VoiceOver reads.
    @Test func theBandCarriesItBesideTheBigCircle() throws {
        let band = try source("Sources/MacUpdater/UpdateBand.swift")
        let lower = try #require(band.range(of: "private func content(")).upperBound
        let upper = try #require(band.range(of: "private func textColumn(")).lowerBound
        let content = band[lower..<upper]
        var placements = 0
        var rest = content.startIndex..<content.endIndex
        while let button = content.range(of: "scanButton", range: rest) {
            let after = content[button.upperBound...].drop(while: \.isWhitespace)
            #expect(after.hasPrefix("roundElement(layout)"), "the button stands right before the circle")
            placements += 1
            rest = button.upperBound..<content.endIndex
        }
        #expect(placements == 3, "regular, compact and narrow")
        #expect(content.contains("VStack(spacing: 8) {"), "narrow stacks it above the circle")
    }

    @Test func updatesBuildsItFromTheStoresGatesInTwoPlaces() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("state: ScanRoundButtonState.resolve(canStartCheck: scan.canStartCheck, canCancelScan: scan.canCancelScan)"))
        #expect(view.contains("onStart: { scan.startCheck() }, onCancel: { scan.cancelScan() }"))
        #expect(view.contains("scanButton: scanRoundButton(style: .band)"), "the band, „Wszystko aktualne” included")
        #expect(view.components(separatedBy: "scanRoundButton(style: .").count == 3, "the band and the first scan's scene, nowhere else")
        #expect(view.contains("ScanProgressScene(progress: scan.progress, catalogRefreshing: scan.isRefreshingCatalog, accessory: scanRoundButton(style: .window))"),
                "in the first scan's scene")
        let scene = try source("Sources/MacUpdater/ScanBusyOverlay.swift")
        #expect(scene.contains("var accessory: ScanRoundButton? = nil"))
    }

    /// Do Homebrew has its own „Skanuj /Applications” and Cofnij re-reads its list on arrival, so
    /// neither carries the updates scan; the toolbar carries none at all.
    @Test func theToolbarAndTheOtherScreensNoLongerScan() throws {
        let content = try source("Sources/MacUpdater/ContentView.swift")
        #expect(!content.contains("ScanControl("))
        #expect(!content.contains("showsScanControl"))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/MacUpdater/ScanControl.swift").path))
        for screen in ["Sources/MacUpdater/MigrationView.swift", "Sources/MacUpdater/RollbackView.swift"] {
            #expect(!(try source(screen)).contains("ScanRoundButton"), "\(screen)")
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
