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

    /// `passwordPromptInstalled` is `PasswordPromptAvailability.isInstalled()`, passed in so the
    /// presentation stays pure. The privileged helper does not count: it cannot answer brew's
    /// `sudo`, so the card must not tick a row the callout above the list still warns about.
    init(dismissed: Bool, hasUpdates: Bool, appManagement: AppManagementPermission,
         touchID: TouchIDSudoConfigurator.State, passwordPromptInstalled: Bool,
         notificationsUnanswered: Bool) {
        isVisible = !dismissed && hasUpdates
        let passwordReady = PasswordPromptNotice.canAskForPassword(installed: passwordPromptInstalled, touchID: touchID)
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
    /// The card's fixed height at the default text size. Fixed rather than intrinsic: a card
    /// whose height follows its rows re-enters AppKit's constraint loop under
    /// `NavigationSplitView`. Sized for the worst row set (App Management denied, Touch ID
    /// available, notifications unanswered), which needs 248 pt in a 360–420 pt detail column
    /// in Polish, plus a margin; 210 pt cut off the buttons that close the card.
    static let baseHeight: CGFloat = 260

    let hasUpdates: Bool

    @AppStorage(ReadinessPresentation.dismissedKey) private var dismissed = false
    @ObservedObject private var agent = MenuBarAgent.shared
    @Environment(\.openSettings) private var openSettings

    @State private var postponed = false
    @State private var appManagement: AppManagementPermission = .unknown
    @State private var probing = false
    @State private var touchID: TouchIDSudoConfigurator.State = .notSupported
    @State private var passwordPromptInstalled = false
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = ReadinessCard.baseHeight

    private var presentation: ReadinessPresentation {
        ReadinessPresentation(dismissed: dismissed, hasUpdates: hasUpdates, appManagement: appManagement,
                              touchID: touchID, passwordPromptInstalled: passwordPromptInstalled,
                              notificationsUnanswered: agent.notificationsUnanswered)
    }

    var body: some View {
        if presentation.isVisible && !postponed {
            card
                .padding(.horizontal, WegaLayout.listGutter)
                .padding(.top, 8)
                .task {
                    let probe = await Task.detached {
                        PasswordPromptNotice.Probe(installed: PasswordPromptAvailability.isInstalled(),
                                                   touchID: TouchIDSudoConfigurator.currentState())
                    }.value
                    touchID = probe.touchID
                    passwordPromptInstalled = probe.installed
                    await agent.refreshNotificationAuthorization()
                }
        }
    }

    private var card: some View {
        ReadinessCardContent(rows: presentation.rows, touchID: touchID, probing: probing, actions: .init(
            postpone: { postponed = true },
            dismiss: { dismissed = true },
            probeAppManagement: probeAppManagement,
            enableTouchID: { openSettings() },
            declineNotifications: { agent.declineNotifications() },
            agreeToNotifications: { Task { await agent.agreeToNotifications() } }
        ))
        .frame(height: cardHeight, alignment: .top)
        .clipped()
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

/// What the card draws for one set of rows. Separate from `ReadinessCard`, which owns the
/// state, so the worst-case row set can be measured against the card's fixed height.
struct ReadinessCardContent: View {
    struct Actions {
        var postpone: @MainActor () -> Void = {}
        var dismiss: @MainActor () -> Void = {}
        var probeAppManagement: @MainActor () -> Void = {}
        var enableTouchID: @MainActor () -> Void = {}
        var declineNotifications: @MainActor () -> Void = {}
        var agreeToNotifications: @MainActor () -> Void = {}
    }

    let rows: [ReadinessPresentation.Row]
    let touchID: TouchIDSudoConfigurator.State
    let probing: Bool
    var actions = Actions()

    @State private var showsHelperExplanation = false

    var body: some View {
        WegaCallout(.info, title: tr("Zanim zaktualizuję pierwszą aplikację"), symbol: "checklist",
                    detail: { rowList }, actions: { EmptyView() })
    }

    private var rowList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(tr("Później"), action: actions.postpone)
                Button(tr("Wszystko jasne"), action: actions.dismiss)
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
                Button(tr("Sprawdź teraz"), action: actions.probeAppManagement).disabled(probing)
                if permission == .denied {
                    Button(tr("Otwórz ustawienia prywatności")) {
                        NSWorkspace.shared.open(AppManagementSettings.paneURL)
                    }
                }
            }
        case .password(let ready):
            line(done: ready, text: tr("Część aplikacji prosi przy aktualizacji o hasło administratora.")) {
                if touchID == .available {
                    Button(tr("Włącz Touch ID"), action: actions.enableTouchID)
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
                Button(tr("Nie włączaj powiadomień"), action: actions.declineNotifications)
                Button(tr("Powiadamiaj"), action: actions.agreeToNotifications)
            }
        }
    }

    private func line<LineActions: View>(done: Bool, text: String,
                                         @ViewBuilder actions: () -> LineActions) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(text, systemImage: done ? "checkmark.circle.fill" : "circle")
                .font(.wega(.subheadline))
                .foregroundStyle(done ? .secondary : .primary)
            HStack(spacing: 6) { actions() }
                .controlSize(.small)
                .padding(.leading, 22)
        }
    }
}
