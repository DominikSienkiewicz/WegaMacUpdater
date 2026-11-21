import Foundation
import MacUpdaterCore

/// UXP-17 — what the menu-bar dropdown says about the work it does in the background, decided
/// away from the menu so each line can be tested.
enum MenuBarMenuCopy {
    /// When the next automatic check is due, and that it needs Wega running — closing the window
    /// does not quit it. An overdue check is due now; with checks switched off, or a check under
    /// way, there is no line.
    static func nextAttempt(lastCheck: Date?, interval: CheckInterval, isChecking: Bool, now: Date) -> String? {
        guard !isChecking, let seconds = interval.seconds else { return nil }
        let next = UpdateSchedule.nextCheckDate(lastCheck: lastCheck, interval: seconds, now: now)
        return trf(
            "Kolejna próba: %@, gdy Wega jest uruchomiona. Zamknięcie okna nie kończy aplikacji.",
            CheckedAtCopy.day(next, now: now)
        )
    }

    /// The check button names the background updates it may start: with any app allowed to
    /// update in the background, a check also installs those apps' updates.
    static func checkTitle(isChecking: Bool, consentCount: Int) -> String {
        if isChecking { return tr("Sprawdzam…") }
        guard consentCount > 0 else { return tr("Sprawdź teraz") }
        return trf("Sprawdź i zaktualizuj w tle (%@)", "\(consentCount)")
    }

    /// „⚠︎ Slack 4.47 → 4.48”: the mark when the notes may describe a security fix, and the
    /// versions when both are known.
    static func entryTitle(_ entry: MenuBarOutdatedEntry) -> String {
        var title = (entry.possibleSecurityFix ? "⚠︎ " : "") + entry.name
        if let from = entry.from, let to = entry.to { title += " \(from) → \(to)" }
        return title
    }
}
