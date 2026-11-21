import Foundation
import MacUpdaterCore
import SwiftUI

/// Shared VoiceOver wording for checkbox-like selection controls.
func selectionAccessibilityValue(_ isSelected: Bool) -> String {
    isSelected ? tr("Zaznaczone") : tr("Niezaznaczone")
}

/// UX-03 — the one decision every never-ending animation in the app has to make.
///
/// A `repeatForever` loop, a blink timer and a randomized idle "trick" schedule share a
/// property that a transition does not: they have no end, so "Ogranicz ruch" cannot merely
/// shorten them. The only honest alternative is not to start them, and to hold the resting
/// frame instead — including when the setting is switched on while the loop is already
/// running, which is why every call site reads this through the environment and re-runs on
/// change rather than deciding once in `onAppear`.
enum ContinuousMotion {
    /// The animation for a forever-repeating effect, or `nil` when the system asks for
    /// reduced motion. `nil` is SwiftUI's "no animation": the animated property snaps to the
    /// value it is being set to instead of looping towards it.
    static func forever(
        _ base: Animation,
        autoreverses: Bool,
        reduceMotion: Bool
    ) -> Animation? {
        reduceMotion ? nil : base.repeatForever(autoreverses: autoreverses)
    }

    /// Whether a perpetual idle loop — the blink timer, the mascot's tricks, the bouncing
    /// ball — may run at all.
    static func loopsIdleAnimations(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}

/// UX-09 — colour-independent cues for the Updates sidebar scan status. Success and failure
/// used to differ only by the icon's colour (green vs red, same glyph) and reached VoiceOver
/// not at all. A failed scan now swaps the icon's *symbol*, and every observable scan state
/// carries a spoken `accessibilityValue`, so the status reaches users who cannot tell the
/// colours apart as well as users on VoiceOver.
struct ScanStatusAccessibilitySemantics: Equatable {
    /// The SF Symbol the icon should render — the caller's base symbol, except on failure,
    /// which substitutes a distinct warning glyph so colour is never the only signal.
    let symbolName: String
    /// What VoiceOver announces as the row's value. `nil` while idle: there is no scan status
    /// to report yet.
    let accessibilityValue: String?

    init(activity: UpdateActivity, baseSymbol: String, progress: UpgradeProgress? = nil) {
        switch activity {
        case .idle:
            symbolName = baseSymbol
            accessibilityValue = nil
        case .scanning:
            symbolName = baseSymbol
            accessibilityValue = tr("Sprawdzanie w toku")
        case .updating:
            symbolName = baseSymbol
            accessibilityValue = progress.map { trf("Aktualizacja w toku, %@ z %@", "\($0.completedUnits)", "\($0.totalUnits)") }
                ?? tr("Aktualizacja w toku")
        case .success:
            symbolName = baseSymbol
            accessibilityValue = tr("Sprawdzono bez błędów")
        case .error:
            symbolName = "exclamationmark.triangle.fill"
            accessibilityValue = tr("Skan nie powiódł się")
        }
    }
}

/// A destructive list may contain two copies with the same display name. Include the
/// installation location only when the caller has determined that the name is ambiguous.
func selectionAccessibilityLabel(
    for app: ApplicationInfo,
    showsLocation: Bool,
    protectionReason: String? = nil
) -> String {
    let base = showsLocation ? "\(app.name), \(app.locationLabel)" : app.name
    guard let protectionReason else { return base }
    return "\(base), \(protectionReason)"
}

enum PackageRowKeyboardCommand {
    case inspect
    case toggleSelection
}

enum PackageRowKeyboardBehavior {
    @discardableResult
    static func handle(
        _ command: PackageRowKeyboardCommand,
        onSelect: (() -> Void)?,
        onToggle: (() -> Void)?
    ) -> Bool {
        switch command {
        case .inspect:
            guard let onSelect else { return false }
            onSelect()
        case .toggleSelection:
            guard let onToggle else { return false }
            onToggle()
        }
        return true
    }
}

enum ManualUpdateRowKeyboardCommand {
    case returnKey
    case spaceKey
}

enum ManualUpdateRowKeyboardBehavior {
    @discardableResult
    static func handle(
        _ command: ManualUpdateRowKeyboardCommand,
        item: ManualOutdatedApp,
        onInspect: ((ManualOutdatedApp) -> Void)?
    ) -> Bool {
        switch command {
        case .returnKey, .spaceKey:
            guard let onInspect else { return false }
            onInspect(item)
            return true
        }
    }
}

struct UninstallOptionAccessibilitySemantics: Equatable {
    let label: String
    let value: String
    let isSelected: Bool

    init(title: String, isSelected: Bool) {
        label = title
        value = selectionAccessibilityValue(isSelected)
        self.isSelected = isSelected
    }
}

enum UninstallDialogKeyboardAction {
    case cancel
    case confirm
}

enum UninstallDialogKeyboardBehavior {
    static func perform(
        _ action: UninstallDialogKeyboardAction,
        zapMode: Bool,
        onCancel: () -> Void,
        onConfirm: (Bool) -> Void
    ) {
        switch action {
        case .cancel:
            onCancel()
        case .confirm:
            onConfirm(zapMode)
        }
    }
}

/// Which way an arrow key moves focus within a group of update rows.
enum RowMoveDirection { case up, down }

/// UXP-21 — what VoiceOver says for an update row: one sentence in the row's reading order,
/// instead of a string of separate texts, a checkbox and a menu to step through.
enum PackageRowAccessibility {
    /// The parts the row shows, joined by ", ": the name, the token line when it adds something to
    /// the name, the versions in their short form, the source, the rollback verdict (or the shield
    /// of a source that keeps no previous version, `rollbackUnavailable`) and the queue.
    static func label(name: String, token: String? = nil, from: String?, to: String?, source: String? = nil,
                      rollback: RollbackProtection.Verdict? = nil, rollbackUnavailable: Bool = false,
                      run: String? = nil, isQueued: Bool) -> String {
        var parts = [name]
        if let token, spoken(token) != spoken(name) { parts.append(token) }
        if let from, let to {
            let shown = VersionDisplay.pair(from: from, to: to)
            parts.append(trf("aktualizacja %@ do %@", shown.from, shown.to))
        }
        if let source { parts.append(source) }
        switch rollback {
        case .protected:   parts.append(tr("z automatycznym cofnięciem"))
        case .unprotected: parts.append(tr("bez automatycznego cofnięcia"))
        case nil:          if rollbackUnavailable { parts.append(tr("bez automatycznego cofnięcia")) }
        }
        if let run { parts.append(run) }
        parts.append(isQueued ? tr("w kolejce") : tr("poza kolejką"))
        return parts.joined(separator: ", ")
    }

    /// What Space does to this row right now, and what Return does.
    static func hint(isQueued: Bool) -> String {
        isQueued ? tr("Spacja usuwa z kolejki, Return pokazuje szczegóły.") : tr("Spacja dodaje do kolejki, Return pokazuje szczegóły.")
    }

    /// "Google Chrome" and "google-chrome" read the same; "firefox@beta" does not read as "Firefox".
    private static func spoken(_ text: String) -> String {
        text.lowercased().filter { !" -_".contains($0) }
    }
}

/// UXP-21 — roving focus inside one group of update rows: Tab reaches the group once, and the
/// arrows move between its rows without leaving it.
enum UpdateRowFocus {
    /// One Tab stop per group: the row focus is on or last left, or the group's first row when
    /// there is none or that row has left the list. None at all while another destination covers
    /// the Updates screen (`updatesOnScreen`) or a run or a scan in place disables the list —
    /// the sections pass both in `onScreen`.
    static func isTabStop(_ key: String, in keys: [String], focused: String?, onScreen: Bool) -> Bool {
        guard onScreen else { return false }
        let stop = focused.flatMap { keys.contains($0) ? $0 : nil } ?? keys.first
        return key == stop
    }

    /// The neighbour inside the group; nil at its edge, so the key press falls through.
    static func neighbour(of key: String, in keys: [String], direction: RowMoveDirection) -> String? {
        guard let index = keys.firstIndex(of: key) else { return nil }
        let next = direction == .down ? keys.index(after: index) : index - 1
        return keys.indices.contains(next) ? keys[next] : nil
    }
}

private struct UpdatesOnScreenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Final review M6 — false while another destination covers the Updates screen, which stays
    /// mounted underneath it. Its rows are then no Tab stops and its controls are disabled, so
    /// Tab and Space cannot reach a row nobody can see.
    var updatesOnScreen: Bool {
        get { self[UpdatesOnScreenKey.self] }
        set { self[UpdatesOnScreenKey.self] = newValue }
    }
}

/// UXP-21 — the sidebar's badges say in words what their colour says: a warning sign on a red
/// badge, and the Updates row names its count and the possible security fixes in it.
enum SidebarBadgeCopy {
    static func text(count: Int, isDanger: Bool) -> String {
        isDanger ? "\u{26A0}\u{FE0E} \(count)" : "\(count)"
    }

    static func updatesLabel(count: Int, security: Int) -> String {
        guard count > 0 else { return tr("Aktualizacje") }
        guard security > 0 else { return trf("Aktualizacje: %@", "\(count)") }
        return trf("Aktualizacje: %@, w tym %@ z możliwą poprawką bezpieczeństwa", "\(count)", "\(security)")
    }
}
