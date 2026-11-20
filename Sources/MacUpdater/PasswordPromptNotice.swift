import Foundation
import SwiftUI
import MacUpdaterCore

/// UXP-07 — when a queued cask needs the administrator password and nothing in this
/// installation can ask for it, the user hears it before the update fails.
enum PasswordPromptNotice {
    static let releasesURL = AppEndpoints.shared.githubReleasesPageURL(repo: "DominikSienkiewicz/WegaMacUpdater")

    static func shouldWarn(installed: Bool, touchID: TouchIDSudoConfigurator.State, queuedNeedingPassword: [String]) -> Bool {
        !installed && touchID != .enabled && !queuedNeedingPassword.isEmpty
    }

    static func message(firstApp: String) -> String {
        trf("Ta kopia Wegi nie umie poprosić o hasło administratora, więc %@ się nie zaktualizuje. Zainstaluj Wegę z pliku .pkg albo włącz Touch ID.", firstApp)
    }
}

/// The warning above the Updates list. It is shown only while it can still be acted on:
/// a queued cask needs the password, no `.pkg` payload is installed and Touch ID is off.
struct PasswordPromptCallout: View {
    let queuedNeedingPassword: [String]

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @State private var touchID: TouchIDSudoConfigurator.State = .notSupported

    var body: some View {
        banner.task(id: queuedNeedingPassword) {
            touchID = await Task.detached { TouchIDSudoConfigurator.currentState() }.value
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let firstApp = queuedNeedingPassword.first,
           PasswordPromptNotice.shouldWarn(installed: PasswordPromptAvailability.isInstalled(),
                                           touchID: touchID,
                                           queuedNeedingPassword: queuedNeedingPassword) {
            WegaCallout(.warning, title: PasswordPromptNotice.message(firstApp: firstApp)) {
                if let url = PasswordPromptNotice.releasesURL {
                    Button(tr("Pobierz .pkg")) { openURL(url) }
                }
                if touchID == .available {
                    Button(tr("Włącz Touch ID")) { openSettings() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}
