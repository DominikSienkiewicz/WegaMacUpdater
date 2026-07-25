import Foundation
import MacUpdaterCore

/// Shared VoiceOver wording for checkbox-like selection controls.
func selectionAccessibilityValue(_ isSelected: Bool) -> String {
    isSelected ? tr("Zaznaczone") : tr("Niezaznaczone")
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
