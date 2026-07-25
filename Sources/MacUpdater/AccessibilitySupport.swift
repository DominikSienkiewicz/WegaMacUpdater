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
