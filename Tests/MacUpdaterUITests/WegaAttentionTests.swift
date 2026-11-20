import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// UXP-27 — the ball waits while something needs the user's attention: a `.danger` banner, a
/// running update (its password and publisher prompts come from the run) or an open
/// confirmation on one of the five screens that raise one. Errors are spoken calmly, in the
/// first person, and Cleanup sniffs while it scans like every other scan.
@Suite("Wega's attention") @MainActor
struct WegaAttentionTests {
    @Test func theBallWaitsForErrorsRunsAndDialogs() {
        #expect(WegaAttention.holdsBall(bannerVariant: .danger, isUpdating: false, dialogOpen: false))
        #expect(WegaAttention.holdsBall(bannerVariant: nil, isUpdating: true, dialogOpen: false))
        #expect(WegaAttention.holdsBall(bannerVariant: nil, isUpdating: false, dialogOpen: true))
        #expect(!WegaAttention.holdsBall(bannerVariant: .success, isUpdating: false, dialogOpen: false))
        #expect(!WegaAttention.holdsBall(bannerVariant: nil, isUpdating: false, dialogOpen: false))
    }

    @Test func anyOpenDialogHoldsIt() {
        var value = false
        WegaAttentionKey.reduce(value: &value) { true }
        WegaAttentionKey.reduce(value: &value) { false }
        #expect(value)
    }

    @Test func theCardStopsPlayingWhileAttentionIsHeld() throws {
        let card = try source("Sources/MacUpdater/WegaCompanionCard.swift")
        #expect(card.contains("playsWithBall: !attentionHeld"))
        #expect(card.contains(".task(id: [playsWithBall, asksForNotifications, reduceMotion])"))
        #expect(try source("Sources/MacUpdater/DetailColumn.swift").contains(".onPreferenceChange(WegaAttentionKey.self)"))
        for file in ["UpdateView", "RollbackView", "UninstallView", "CleanupView", "MigrationView"] {
            #expect(try source("Sources/MacUpdater/\(file).swift").contains(".wegaAttention("), "\(file)")
        }
    }

    @Test func errorsAreSpokenCalmlyInTheFirstPerson() throws {
        let adoption = try source("Sources/MacUpdater/ScanStore+Adoption.swift")
        #expect(!adoption.contains("Coś poszło nie tak z %@."))
        #expect(!adoption.contains("tr(\"Błąd instalacji\")") && !adoption.contains("\"Błąd instalacji %@\""))
        #expect(adoption.contains("trf(\"Nie udało mi się zainstalować %@\", \"\\(token)\")"))
        #expect(try source("Sources/MacUpdater/MigrationStore.swift")
            .contains("trf(\"Nie udało mi się zainstalować %@. Spróbuj jeszcze raz.\", \"\\(app.name)\")"))
        withLanguage(.en) {
            #expect(trf("Nie udało mi się zainstalować %@. Spróbuj jeszcze raz.", "Zoom") == "I couldn't install Zoom. Try again.")
        }
    }

    @Test func cleanupSniffsWhileItScans() throws {
        let cleanup = try source("Sources/MacUpdater/CleanupView.swift")
        #expect(cleanup.contains("SniffingScene(caption: tr(\"Przeglądam katalogi z PATH i wersje narzędzi. Niczego nie zmieniam.\"))"))
        #expect(!cleanup.contains("pose: .sniff, title: tr(\"Skanuję…\")"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
