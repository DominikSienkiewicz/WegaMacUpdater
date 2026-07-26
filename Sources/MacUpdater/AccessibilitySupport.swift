import Foundation
import MacUpdaterCore

/// Shared VoiceOver wording for checkbox-like selection controls.
func selectionAccessibilityValue(_ isSelected: Bool) -> String {
    isSelected ? tr("Zaznaczone") : tr("Niezaznaczone")
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

    init(activity: UpdateActivity, baseSymbol: String) {
        switch activity {
        case .idle:
            symbolName = baseSymbol
            accessibilityValue = nil
        case .scanning:
            symbolName = baseSymbol
            accessibilityValue = tr("Sprawdzanie w toku")
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
    showsLocation: Bool
) -> String {
    showsLocation ? "\(app.name), \(app.locationLabel)" : app.name
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
