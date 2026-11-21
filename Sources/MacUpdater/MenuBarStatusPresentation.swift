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
    var run: WindowRunStatus?
    /// UXP-17 — how many of the updates have notes that may describe a security fix.
    var securityCount: Int = 0

    /// The count, then the incomplete-check note, then the security nuance — the band's order.
    var statusText: String {
        if let run { return trf("Aktualizuję %@ z %@…", "\(run.completedUnits)", "\(run.totalUnits)") }
        if isChecking { return tr("Sprawdzam aktualizacje…") }
        if failed && count == 0 { return tr("Nie udało się sprawdzić") }
        if count > 0 {
            var parts = [trp("%@ aktualizacji dostępnych", count)]
            if incomplete { parts.append(tr("sprawdzanie niepełne")) }
            if securityCount > 0 { parts.append(trp("%@ z możliwą poprawką bezp.", securityCount)) }
            return parts.joined(separator: " · ")
        }
        if lastCheck == nil { return tr("Jeszcze nie sprawdzano") }
        return tr("Wszystko aktualne")
    }

    var accessibilityLabel: String { statusText }
}

/// UXP-09 — what the menu bar shows of an update run started in the window: how far it has got,
/// and whether a stop has been asked for. Nothing else — a stage change inside one package
/// changes nothing the menu draws, so it is not part of the value.
struct WindowRunStatus: Equatable {
    let completedUnits: Int
    let totalUnits: Int
    let isStopping: Bool

    /// The menu's stop item says what the window's says, before and after the click.
    var stopLabel: String { UpdateRunCopy.stopLabel(isStopping: isStopping) }
    var canStop: Bool { !isStopping }
}
