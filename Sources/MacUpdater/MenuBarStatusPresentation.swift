import Foundation
import MacUpdaterCore

/// What the menu-bar item and its dropdown say about the last check, decided away from the views.
///
/// A zero is only "up to date" when the check was complete: a check where a source failed finds
/// nothing about that source, and saying "Wszystko aktualne" then would be a false all-clear.
struct MenuBarStatusPresentation: Equatable {
    let count: Int
    let isChecking: Bool
    let failed: Bool
    let incomplete: Bool
    let lastCheck: Date?

    var statusText: String {
        if isChecking { return tr("Sprawdzam aktualizacje…") }
        if failed && count == 0 { return tr("Nie udało się sprawdzić") }
        if incomplete && count > 0 {
            return trp("%@ aktualizacji dostępnych", count) + " · " + tr("sprawdzanie niepełne")
        }
        if count > 0 { return trp("%@ aktualizacji dostępnych", count) }
        if lastCheck == nil { return tr("Jeszcze nie sprawdzano") }
        return tr("Wszystko aktualne")
    }

    var accessibilityLabel: String { statusText }
}
