import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-17 — the menu-bar dropdown named the apps but led nowhere, said "Sprawdzono 23:55" the
/// morning after, never said when it would look again or that closing the window keeps it
/// running, and its "Sprawdź teraz" hid that it may also install the apps allowed to update in
/// the background.
@Suite("Menu bar menu") @MainActor
struct MenuBarMenuTests {
    let calendar = Calendar(identifier: .gregorian)
    let now = DateComponents(calendar: .init(identifier: .gregorian), year: 2026, month: 11, day: 21, hour: 0, minute: 5).date!

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func freshnessNamesTheDay() {
        let lateYesterday = now.addingTimeInterval(-10 * 60)
        let time = lateYesterday.formatted(date: .omitted, time: .shortened)
        withLanguage(.pl) {
            #expect(CheckedAtCopy.checked(at: now.addingTimeInterval(-60), now: now, calendar: calendar)
                    == trf("Sprawdzono %@", now.addingTimeInterval(-60).formatted(date: .omitted, time: .shortened)))
            #expect(CheckedAtCopy.checked(at: lateYesterday, now: now, calendar: calendar) == "Sprawdzono wczoraj, \(time)")
        }
        withLanguage(.en) { #expect(CheckedAtCopy.checked(at: lateYesterday, now: now, calendar: calendar) == "Checked yesterday, \(time)") }
        let old = now.addingTimeInterval(-4 * 86_400)
        #expect(CheckedAtCopy.checked(at: old, now: now, calendar: calendar) == trf("Sprawdzono %@", old.formatted(date: .abbreviated, time: .shortened)))
    }

    @Test func aDayIsNamedAroundToday() {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let tomorrow = now.addingTimeInterval(26 * 3600)
        let yesterday = now.addingTimeInterval(-10 * 60)
        let later = now.addingTimeInterval(3 * 86_400)
        withLanguage(.pl) {
            #expect(CheckedAtCopy.day(now, now: now, calendar: calendar) == "dziś, \(time(now))")
            #expect(CheckedAtCopy.day(yesterday, now: now, calendar: calendar) == "wczoraj, \(time(yesterday))")
            #expect(CheckedAtCopy.day(tomorrow, now: now, calendar: calendar) == "jutro, \(time(tomorrow))")
        }
        withLanguage(.en) { #expect(CheckedAtCopy.day(tomorrow, now: now, calendar: calendar) == "tomorrow, \(time(tomorrow))") }
        #expect(CheckedAtCopy.day(later, now: now, calendar: calendar) == later.formatted(date: .abbreviated, time: .shortened))
    }

    @Test func theNextAttemptIsHonestAboutTheAppRunning() {
        let last = now.addingTimeInterval(-3 * 3600)
        let next = last.addingTimeInterval(6 * 3600)
        withLanguage(.pl) {
            #expect(MenuBarMenuCopy.nextAttempt(lastCheck: last, interval: .every6Hours, now: now)
                    == "Kolejna próba: dziś, \(next.formatted(date: .omitted, time: .shortened)), gdy Wega jest uruchomiona. Zamknięcie okna nie kończy aplikacji.")
            #expect(MenuBarMenuCopy.nextAttempt(lastCheck: last, interval: .off, now: now) == nil)
            #expect(MenuBarMenuCopy.nextAttempt(lastCheck: now.addingTimeInterval(-2 * 86_400), interval: .daily, now: now)?
                .contains(now.formatted(date: .omitted, time: .shortened)) == true, "an overdue attempt is now")
        }
        withLanguage(.en) {
            #expect(MenuBarMenuCopy.nextAttempt(lastCheck: last, interval: .every6Hours, now: now)?
                .hasPrefix("Next attempt: today, ") == true)
        }
    }

    @Test func theCheckButtonSaysWhenItMayInstall() {
        withLanguage(.pl) {
            #expect(MenuBarMenuCopy.checkTitle(isChecking: false, consentCount: 0) == tr("Sprawdź teraz"))
            #expect(MenuBarMenuCopy.checkTitle(isChecking: false, consentCount: 2) == "Sprawdź i zaktualizuj w tle (2)")
            #expect(MenuBarMenuCopy.checkTitle(isChecking: true, consentCount: 2) == tr("Sprawdzam…"))
        }
        withLanguage(.en) { #expect(MenuBarMenuCopy.checkTitle(isChecking: false, consentCount: 1) == "Check and Update in Background (1)") }
    }

    @Test func aRowNamesTheVersionsAndFlagsAPossibleFix() {
        let entry = MenuBarOutdatedEntry(key: "m:/Applications/Slack.app", name: "Slack", from: "4.47", to: "4.48", possibleSecurityFix: true)
        #expect(MenuBarMenuCopy.entryTitle(entry) == "⚠︎ Slack 4.47 → 4.48")
        let unversioned = MenuBarOutdatedEntry(key: "c:zoom", name: "Zoom", from: nil, to: "6.0", possibleSecurityFix: false)
        #expect(MenuBarMenuCopy.entryTitle(unversioned) == "Zoom")
        withLanguage(.pl) {
            #expect(MenuBarStatusPresentation(count: 3, isChecking: false, failed: false, incomplete: false, lastCheck: now, securityCount: 1).statusText
                    == trp("%@ aktualizacji dostępnych", 3) + " · " + trp("%@ z możliwą poprawką bezp.", 1))
            #expect(MenuBarStatusPresentation(count: 3, isChecking: false, failed: false, incomplete: true, lastCheck: now, securityCount: 1).statusText
                    == trp("%@ aktualizacji dostępnych", 3) + " · " + tr("sprawdzanie niepełne") + " · "
                    + trp("%@ z możliwą poprawką bezp.", 1),
                    "the incomplete note comes before the nuance, as in the band")
        }
        withLanguage(.en) { #expect(tr("Otwórz Wegę") == "Open Wega" && tr("Zakończ Wegę") == "Quit Wega") }
    }

    @Test func aRowOpensItselfInTheWindow() throws {
        let menu = try source("Sources/MacUpdater/MenuBarScene.swift")
        #expect(menu.contains("ForEach(agent.outdatedEntries.prefix(Self.maxListedApps), id: \\.key)"))
        #expect(menu.contains("NotificationRouter.shared.route(to: .updates(.all))"))
        #expect(menu.contains("agent.revealInWindow?(entry.key)"))
        #expect(menu.contains("MenuBarMenuCopy.checkTitle(isChecking: agent.isChecking, consentCount: consents.consents.count)"))
        #expect(!menu.contains("tr(\"Otwórz Wega\")") && !menu.contains("tr(\"Zakończ Wega\")"))
        #expect(try source("Sources/MacUpdater/ScanStore.swift").contains("MenuBarAgent.shared.revealInWindow = { [weak self] key in self?.inspectedKey = key }"))
    }

    /// The row's key reaches the store before the window has appeared, and the window then
    /// re-applies its filter (on appearing, and when the route changes it). On "all updates"
    /// every row is listed, so the row the menu asked for must stay inspected; a narrower
    /// filter still clears an inspection it may no longer list.
    @Test func theWindowKeepsTheRowTheMenuRevealed() {
        let runner = ScanStoreRuntimeProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "{}", stderr: "") }
        let store = makeScanStoreRuntimeHarness(runner: runner).store
        let key = "c:menu-reveal-\(UUID().uuidString)"
        store.inspectedKey = key
        UpdateFilterInteraction.apply(.all, to: store)
        #expect(store.inspectedKey == key)
        UpdateFilterInteraction.apply(.cli, to: store)
        #expect(store.inspectedKey == nil)
    }
}
