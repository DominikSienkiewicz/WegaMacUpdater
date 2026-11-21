import AppKit
import Foundation
import SwiftUI
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// UXP-27 — the ball waits while something needs the user's attention: a `.danger` banner, a
/// running update (its password and publisher prompts come from the run) or an open
/// confirmation on one of the screens that raise one, Logs' "Wyczyścić logi?" included. Errors
/// are spoken calmly, in the first person, and Cleanup sniffs while it scans like every other scan.
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
        WegaAttentionKey.reduce(value: &value) { false }
        #expect(!value, "nothing open holds nothing")
        WegaAttentionKey.reduce(value: &value) { true }
        WegaAttentionKey.reduce(value: &value) { false }
        #expect(value)
    }

    /// The Docker Desktop confirmation sits inside Updates, whose own dialogs are closed: the
    /// screen's report must not hide the one made inside it.
    @Test func aDialogInsideAScreenStillHoldsTheBall() {
        #expect(reportedAttention(Color.clear.wegaAttention(true)), "the harness sees a report")
        #expect(reportedAttention(Color.clear.wegaAttention(true).wegaAttention(false)))
        #expect(!reportedAttention(Color.clear.wegaAttention(false).wegaAttention(false)))
    }

    /// Each screen reports its own dialogs and errors, not a constant.
    static let screens: [(file: String, held: String)] = [
        ("UpdateView", ".wegaAttention(showUpdateConfirmation || scan.pendingForceRestart != nil)"),
        ("DockerDesktopUpdateActions", ".wegaAttention(confirmHomebrew)"),
        ("RollbackView", ".wegaAttention(showUndoConfirmation)"),
        ("UninstallView", ".wegaAttention(showDialog || showForceQuit || scanError != nil)"),
        ("CleanupView", ".wegaAttention(confirming != nil || showsPathWarning || !errorMessages.isEmpty)"),
        ("MigrationView", ".wegaAttention(confirmingApp != nil || migration.duplicateConfirmation != nil || migration.pendingForceTermination != nil || errorMessage != nil || banner?.variant == .danger)"),
        // Final review I2 — clearing the logs is a removal confirmation (owner's Q4).
        ("LogsView", ".wegaAttention(confirmingClear)"),
    ]

    @Test func everyScreenReportsWhatIsOpenOnIt() throws {
        for screen in Self.screens {
            let text = try source("Sources/MacUpdater/\(screen.file).swift")
            #expect(text.contains(screen.held), "\(screen.file)")
            #expect(!text.contains(".wegaAttention(false)") && !text.contains(".wegaAttention(true)"), "\(screen.file)")
        }
        let cleanup = try source("Sources/MacUpdater/CleanupView.swift")
        #expect(cleanup.contains("ForEach(errorMessages, id: \\.self) { ErrorBanner(message: $0) }"),
                "the banners and the hold read one list")
    }

    @Test func theHoldTravelsFromTheScreensToTheCard() throws {
        let detail = try source("Sources/MacUpdater/DetailColumn.swift")
        #expect(detail.contains(".onPreferenceChange(WegaAttentionKey.self) { dialogOpen = $0 }"))
        #expect(detail.contains(".onPreferenceChange(WegaAttentionKey.self) { inspectorDialogOpen = $0 }"),
                "the inspector draws the same Docker confirmation as the list")
        #expect(detail.contains(
            "WegaAttention.holdsBall(bannerVariant: scan.banner?.variant, isUpdating: scan.updating, dialogOpen: dialogOpen || inspectorDialogOpen)"
        ))
        #expect(detail.contains(".onChange(of: holdsBall, initial: true) { _, held in wegaAttentionHeld = held }"))
        let content = try source("Sources/MacUpdater/ContentView.swift")
        #expect(content.contains("wegaAttentionHeld: wegaAttentionHeld"))
        #expect(content.contains("wegaAttentionHeld: $wegaAttentionHeld"))
        #expect(try source("Sources/MacUpdater/SidebarList.swift").contains("attentionHeld: wegaAttentionHeld"))
    }

    @Test func theCardStopsPlayingWhileAttentionIsHeld() throws {
        let card = try source("Sources/MacUpdater/WegaCompanionCard.swift")
        #expect(card.contains("playsWithBall: !attentionHeld"))
        #expect(card.contains(".task(id: [playsWithBall, asksForNotifications, reduceMotion])"))
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

    struct VerificationLine {
        let verdict: CaskValidationVerdict
        let polish: String
        let english: String
    }

    /// A failed check after a manual install: Wega says what she did, calmly, naming the cask.
    static let verificationLines: [VerificationLine] = [
        VerificationLine(verdict: .rolledBack,
                         polish: "Nowa wersja zoom nie przeszła kontroli, więc przywróciłam poprzednią.",
                         english: "The new version of zoom failed its check, so I restored the previous one."),
        VerificationLine(verdict: .rollbackFailed,
                         polish: "Nowa wersja zoom nie przeszła kontroli, a poprzedniej nie udało mi się przywrócić.",
                         english: "The new version of zoom failed its check, and I couldn't restore the previous one."),
        VerificationLine(verdict: .publisherChanged(old: "AAA", new: "BBB"),
                         polish: "Zainstalowałam zoom, ale zmienił się wydawca — sprawdź go.",
                         english: "I installed zoom, but the publisher changed — please check it."),
        VerificationLine(verdict: .publisherChangedAndRolledBack(old: "AAA", new: nil),
                         polish: "Zmienił się wydawca zoom, więc przywróciłam poprzednią wersję.",
                         english: "The publisher of zoom changed, so I restored the previous version."),
        VerificationLine(verdict: .notUpgraded,
                         polish: "Nie udało mi się zaktualizować zoom — na dysku została poprzednia wersja.",
                         english: "I couldn't update zoom — the previous version is still on disk."),
        VerificationLine(verdict: .replacedByAppUpdater(version: "2.0"),
                         polish: "Aktualizator zoom podmienił wersję, którą zainstalowałam.",
                         english: "zoom's own updater replaced the version I installed."),
    ]

    @Test func aFailedCheckIsSpokenCalmlyInTheFirstPerson() throws {
        #expect(ManualInstallWegaLine.text(for: .healthy, token: "zoom") == nil)
        for line in Self.verificationLines {
            withLanguage(.pl) { #expect(ManualInstallWegaLine.text(for: line.verdict, token: "zoom") == line.polish) }
            withLanguage(.en) { #expect(ManualInstallWegaLine.text(for: line.verdict, token: "zoom") == line.english) }
        }
        let adoption = try source("Sources/MacUpdater/ScanStore+Adoption.swift")
        #expect(!adoption.contains("line: title"), "a banner title is not Wega speaking")
        #expect(adoption.contains("ManualInstallWegaLine.text(for: verdict, token: token)"))
    }

    @Test func cleanupSniffsWhileItScans() throws {
        let cleanup = try source("Sources/MacUpdater/CleanupView.swift")
        #expect(cleanup.contains("SniffingScene(caption: tr(\"Przeglądam katalogi z PATH i wersje narzędzi. Niczego nie zmieniam.\"))"))
        #expect(!cleanup.contains("pose: .sniff, title: tr(\"Skanuję…\")"))
    }

    private func reportedAttention(_ view: some View) -> Bool {
        var held = false
        let host = NSHostingView(rootView: view.frame(width: 20, height: 20)
            .onPreferenceChange(WegaAttentionKey.self) { held = $0 })
        host.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        host.layoutSubtreeIfNeeded()
        return held
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
