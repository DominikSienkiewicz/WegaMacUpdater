import SwiftUI
import MacUpdaterCore

/// The app's native Settings scene (⌘,). Hosts what used to be the Info tab —
/// diagnostics, Touch ID, privileged helper, GitHub token, self-update — where
/// macOS users expect app settings to live. `onWegaState` is a no-op here: the
/// Settings window has no mascot panel to drive.
struct SettingsView: View {
    var body: some View {
        InfoView(onWegaState: { _ in })
            .frame(width: 640, height: 600)
    }
}
