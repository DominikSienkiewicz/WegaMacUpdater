import AppKit
import Foundation
import MacUpdaterCore
import SwiftUI
import Testing

@testable import WegaMacUpdater

/// Owner, 2026-11-22 (option B): the toolbar's „Sprawdź teraz”/„Anuluj” was hard to find, so the
/// scan action moved to a round button where the scan is reported: beside the band's big circle,
/// beside the „Wszystko aktualne” heading, and in the first scan's scene. Do Homebrew and Cofnij
/// get none; ⌘R and ⌘. still work everywhere.
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

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
