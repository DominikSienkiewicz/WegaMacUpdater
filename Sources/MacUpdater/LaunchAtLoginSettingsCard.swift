import AppKit
import MacUpdaterCore
import SwiftUI

/// BG-02 — the explicit "Uruchamiaj przy logowaniu" toggle. It reads the real
/// `SMAppService.mainApp` login-item status through `LaunchAtLoginController` and lets the
/// user turn Wega's launch-at-login on or off. With it on, macOS relaunches Wega at login,
/// so the background mode (schedule, badge, notifications, silent updates) keeps working
/// after a restart of the Mac instead of dying at the first reboot.
struct LaunchAtLoginSettingsCard: View {
    @StateObject private var controller = LaunchAtLoginController()
    @State private var isWorking = false

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "power", title: tr("Uruchamiaj przy logowaniu")) {
                    statusBadge
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Tryb tła — harmonogram, licznik, powiadomienia i ciche aktualizacje — działa tylko, gdy Wega jest uruchomiona. Włącz tę opcję, aby macOS uruchamiał Wegę przy logowaniu i tło działało również po restarcie Maca."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: Binding(
                        get: { controller.state.isOn },
                        set: { desired in
                            isWorking = true
                            Task {
                                await controller.setEnabled(desired)
                                isWorking = false
                            }
                        }
                    )) {
                        Text(tr("Uruchamiaj Wegę przy logowaniu")).font(.wega(.callout))
                    }
                    .toggleStyle(.switch)
                    .disabled(isWorking)

                    if controller.state.needsSystemSettings {
                        Text(tr("Element logowania został wyłączony w Ustawieniach systemowych. Włącz go ponownie w Ustawienia → Elementy logowania."))
                            .font(.wega(.subheadline))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            controller.openLoginItemsSettings()
                        } label: {
                            Label(tr("Otwórz Ustawienia → Elementy logowania"), systemImage: "gearshape")
                        }
                        .controlSize(.small)
                    }

                    if let error = controller.errorMessage {
                        Text(error)
                            .font(.wega(.subheadline))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
        }
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch controller.state {
        case .enabled:          WegaBadge(label: tr("Aktywne"), variant: .success)
        case .requiresApproval: WegaBadge(label: tr("Wymaga zgody"), variant: .manual)
        case .disabled:         EmptyView()
        }
    }
}
