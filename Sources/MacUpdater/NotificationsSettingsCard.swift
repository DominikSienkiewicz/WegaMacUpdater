import AppKit
import MacUpdaterCore
import SwiftUI

/// UXP-05 — where the notification decision can be changed. The in-app card asks once and a
/// "no" used to be permanent; this switch is the way back, and the way to turn them off again.
struct NotificationsSettingsCard: View {
    @ObservedObject private var agent = MenuBarAgent.shared
    @State private var isWorking = false

    private static let systemSettingsURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "bell", title: tr("Powiadomienia")) { EmptyView() }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { agent.notificationsEnabledByUser },
                        set: { desired in
                            isWorking = true
                            Task {
                                await agent.setNotificationsEnabled(desired)
                                isWorking = false
                            }
                        }
                    )) {
                        Text(tr("Powiadamiaj o nowych aktualizacjach")).font(.wega(.callout))
                    }
                    .toggleStyle(.switch)
                    .disabled(isWorking)

                    if agent.systemNotificationAuthorization == .denied {
                        Button {
                            if let url = URL(string: Self.systemSettingsURL) { NSWorkspace.shared.open(url) }
                        } label: {
                            Label(tr("Otwórz ustawienia powiadomień"), systemImage: "gearshape")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
            }
        }
        .task { await agent.refreshNotificationAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await agent.refreshNotificationAuthorization() }
        }
    }
}
