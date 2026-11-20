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

    /// What the one-time probe learned. Until it exists the notice stays silent: an unprobed
    /// Touch ID state is not a disabled one.
    struct Probe: Equatable {
        let installed: Bool
        let touchID: TouchIDSudoConfigurator.State
    }

    static func shouldWarn(probe: Probe?, queuedNeedingPassword: [String]) -> Bool {
        guard let probe else { return false }
        return shouldWarn(installed: probe.installed, touchID: probe.touchID, queuedNeedingPassword: queuedNeedingPassword)
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
    @State private var probe: PasswordPromptNotice.Probe? = PasswordPromptProbeCache.value

    var body: some View {
        Group { banner }
            .task(id: queuedNeedingPassword) {
                let fresh = await Task.detached {
                    PasswordPromptNotice.Probe(installed: PasswordPromptAvailability.isInstalled(),
                                               touchID: TouchIDSudoConfigurator.currentState())
                }.value
                PasswordPromptProbeCache.value = fresh
                probe = fresh
            }
    }

    @ViewBuilder
    private var banner: some View {
        if let firstApp = queuedNeedingPassword.first, let probe,
           PasswordPromptNotice.shouldWarn(probe: probe, queuedNeedingPassword: queuedNeedingPassword) {
            WegaCallout(.warning, title: PasswordPromptNotice.message(firstApp: firstApp)) {
                if let url = PasswordPromptNotice.releasesURL {
                    Button(tr("Pobierz .pkg")) { openURL(url) }
                }
                if probe.touchID == .available {
                    Button(tr("Włącz Touch ID")) { openSettings() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

/// Last probe result for the app's lifetime, so a recreated view does not start blank.
@MainActor
enum PasswordPromptProbeCache {
    static var value: PasswordPromptNotice.Probe?
}
