import SwiftUI
import MacUpdaterCore

/// Speaks a finished piece of work to VoiceOver. A protocol so tests record the text
/// instead of posting a system notification.
@MainActor
protocol AccessibilityAnnouncing: AnyObject {
    func announce(_ text: String)
}

@MainActor
final class LiveAccessibilityAnnouncer: AccessibilityAnnouncing {
    func announce(_ text: String) {
        var speech = AttributedString(text)
        speech.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(speech).post()
    }
}

/// The announcement texts, built in the language active when the work finishes.
enum AnnouncementCopy {
    static func scanFinished(updates: Int, complete: Bool) -> String {
        let sentence = trp("Skan zakończony: %@ aktualizacji.", updates)
        return complete ? sentence : sentence + " " + tr("Sprawdzanie niepełne.")
    }

    static func scanFailed() -> String {
        tr("Nie udało się sprawdzić aktualizacji")
    }

    static func runFinished(updated: Int, total: Int, needsAttention: [String]) -> String {
        let sentence = trf("Aktualizacja zakończona: %@ z %@.", "\(updated)", "\(total)")
        guard !needsAttention.isEmpty else { return sentence }
        let names = needsAttention.joined(separator: ", ")
        let attention = needsAttention.count == 1
            ? trf("%@ wymaga uwagi.", names)
            : trf("%@ wymagają uwagi.", names)
        return sentence + " " + attention
    }

    static func runStopped(updated: Int, total: Int) -> String {
        trf("Aktualizacja zatrzymana: zaktualizowano %@ z %@.", "\(updated)", "\(total)")
    }

    static func uninstallNothingRemoved() -> String {
        tr("Nic nie odinstalowano. Szczegóły są na liście wyników.")
    }

    static func uninstallFinished(removed: Int) -> String {
        trp("Odinstalowano %@ aplikacji.", removed)
    }
}
