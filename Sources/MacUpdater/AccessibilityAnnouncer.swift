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
        return sentence + " " + trf("%@ wymaga uwagi.", needsAttention.joined(separator: ", "))
    }

    static func uninstallFinished(removed: Int) -> String {
        trp("Odinstalowano %@ aplikacji.", removed)
    }
}
