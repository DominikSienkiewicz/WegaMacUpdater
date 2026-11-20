import AppKit
import MacUpdaterCore
import SwiftUI

// MARK: - Presentation (UXP-06)

/// What the card before the first update announces. Pure, so which rows appear can be pinned
/// in a test: the card asks about nothing the update will not need, and answers nothing the
/// Mac already settled.
struct ReadinessPresentation: Equatable {
    enum Row: Equatable { case checking, replaceApps(AppManagementPermission), password(ready: Bool), notifications }

    /// Written when the user closes the card, and by the first update that ends cleanly.
    static let dismissedKey = "wega.readiness.dismissed"

    let isVisible: Bool
    let rows: [Row]

    init(dismissed: Bool, hasUpdates: Bool, appManagement: AppManagementPermission,
         touchID: TouchIDSudoConfigurator.State, helper: PrivilegedHelperClient.Status,
         notificationsUnanswered: Bool) {
        isVisible = !dismissed && hasUpdates
        let passwordReady = touchID == .enabled || helper == .enabled
        var rows: [Row] = [.checking, .replaceApps(appManagement), .password(ready: passwordReady)]
        if notificationsUnanswered { rows.append(.notifications) }
        self.rows = rows
    }
}

// MARK: - Card

/// UXP-06 — announces what the first update will need (App Management, the administrator
/// password, notifications) instead of letting the user find out through a failure. Its
/// height is fixed for every row state, so it never moves the list.
struct ReadinessCard: View {
    let hasUpdates: Bool

    @AppStorage(ReadinessPresentation.dismissedKey) private var dismissed = false
    @ObservedObject private var agent = MenuBarAgent.shared
    @Environment(\.openSettings) private var openSettings

    @State private var postponed = false
    @State private var appManagement: AppManagementPermission = .unknown
    @State private var probing = false
    @State private var touchID: TouchIDSudoConfigurator.State = .notSupported
    @State private var helper: PrivilegedHelperClient.Status = .notRegistered
    @State private var showsHelperExplanation = false
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 210

    private var presentation: ReadinessPresentation {
        ReadinessPresentation(dismissed: dismissed, hasUpdates: hasUpdates, appManagement: appManagement,
                              touchID: touchID, helper: helper,
                              notificationsUnanswered: agent.notificationsUnanswered)
    }

    var body: some View {
        if presentation.isVisible && !postponed {
            card
                .padding(.horizontal, WegaLayout.listGutter)
                .padding(.top, 8)
                .task {
                    touchID = await Task.detached { TouchIDSudoConfigurator.currentState() }.value
                    helper = PrivilegedHelperClient.shared.status
                    await agent.refreshNotificationAuthorization()
                }
        }
    }

    private var card: some View {
        WegaCallout(.info, title: tr("Zanim zaktualizuję pierwszą aplikację"), symbol: "checklist",
                    detail: { rows }, actions: { EmptyView() })
            .frame(height: cardHeight, alignment: .top)
            .clipped()
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(presentation.rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(tr("Później")) { postponed = true }
                Button(tr("Wszystko jasne")) { dismissed = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaHoneyFill)
                    .foregroundStyle(Color.wegaInk)
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func rowView(_ row: ReadinessPresentation.Row) -> some View {
        switch row {
        case .checking:
            line(done: true, text: tr("Sprawdzanie działa bez żadnych uprawnień.")) { EmptyView() }
        case .replaceApps(let permission):
            line(done: permission == .granted,
                 text: tr("Podmiana aplikacji w /Applications — macOS musi na to pozwolić.")) {
                Button(tr("Sprawdź teraz"), action: probeAppManagement).disabled(probing)
                if permission == .denied {
                    Button(tr("Otwórz ustawienia prywatności")) {
                        NSWorkspace.shared.open(AppManagementSettings.paneURL)
                    }
                }
            }
        case .password(let ready):
            line(done: ready, text: tr("Część aplikacji prosi przy aktualizacji o hasło administratora.")) {
                if touchID == .available {
                    Button(tr("Włącz Touch ID")) { openSettings() }
                }
                Button(tr("Co robi pomocnik?")) { showsHelperExplanation = true }
                    .popover(isPresented: $showsHelperExplanation) {
                        Text(tr("Pomocnik Wegi działa jako root i umie tylko cztery rzeczy: zainstalować zweryfikowany pakiet Wegi, włączyć Touch ID dla sudo, przywrócić kopię aplikacji sprzed aktualizacji, przenieść do Kosza aplikację należącą do roota. Przy każdym połączeniu sprawdza podpis Wegi. Jest opcjonalny."))
                            .font(.wega(.callout))
                            .frame(width: 300)
                            .padding(12)
                    }
            }
        case .notifications:
            line(done: false, text: tr("Powiadamiać o nowych aktualizacjach?")) {
                Button(tr("Nie włączaj powiadomień")) { agent.declineNotifications() }
                Button(tr("Powiadamiaj")) { Task { await agent.agreeToNotifications() } }
            }
        }
    }

    private func line<Actions: View>(done: Bool, text: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(text, systemImage: done ? "checkmark.circle.fill" : "circle")
                .font(.wega(.subheadline))
                .foregroundStyle(done ? .secondary : .primary)
            HStack(spacing: 6) { actions() }
                .controlSize(.small)
                .padding(.leading, 22)
        }
    }

    /// The probe touches the disk, so it runs only on the click and off the main actor.
    private func probeAppManagement() {
        probing = true
        Task {
            appManagement = await Task.detached { AppManagementPermissionProbe.liveStatus() }.value
            probing = false
        }
    }
}
