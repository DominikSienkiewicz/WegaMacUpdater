import SwiftUI
import MacUpdaterCore

/// The app's native Settings scene (⌘,). Hosts what used to be the Info tab —
/// diagnostics, Touch ID, privileged helper, GitHub token, self-update — where
/// macOS users expect app settings to live. The window has no Wega, so each card
/// shows its own messages under its buttons (UXP-15).
struct SettingsView: View {
    var body: some View {
        InfoView()
            .frame(
                minWidth: WegaLayout.settingsMinWidth,
                idealWidth: WegaLayout.settingsIdealWidth,
                maxWidth: .infinity,
                minHeight: WegaLayout.settingsMinHeight,
                idealHeight: WegaLayout.settingsIdealHeight,
                maxHeight: .infinity
            )
    }
}
