import SwiftUI
import MacUpdaterCore

// MARK: - Brew invitation (F4)

/// Homebrew unlocks the brew formula/cask sources. Its absence is an invitation, not an
/// error: Wega still checks the Mac App Store, Sparkle, the nine vendor feeds and npm, so
/// the app stays fully usable and this card sits above the working UI rather than in front
/// of it. The install command remains copyable, but it is no longer a toll gate.
private struct BrewInviteCard: View {
    let onRecheck: () -> Void

    private let installCommand = AppEndpoints.shared.homebrewInstallCommand

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(Color.wegaHoney)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Zainstaluj Homebrew, żeby odblokować więcej aktualizacji"))
                    .font(.system(size: 12, weight: .semibold))
                Text(tr("Wega działa bez niego — sprawdza Mac App Store, Sparkle, feedy producentów i npm. Homebrew dokłada formuły i caski."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(installCommand)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button(copied ? tr("Skopiowano") : tr("Kopiuj polecenie")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(installCommand, forType: .string)
                copied = true
            }
            Button(tr("Sprawdź ponownie"), action: onRecheck)
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color.wegaInk)
        }
        .padding(12)
        .background(Color.wegaHoney.opacity(0.06))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

// MARK: - Notification explanation (M3d)

/// Explains, in Wega's own window, why it would like to post notifications — before macOS
/// throws its one-shot permission dialog at a user who is looking at another app. Appears
/// only once the background agent has actually found something worth announcing, and never
/// again after the user answers either way.
private struct NotificationExplanationCard: View {
    @ObservedObject private var agent = MenuBarAgent.shared

    var body: some View {
        if agent.needsNotificationExplanation {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bell.badge").foregroundStyle(Color.wegaHoney)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Powiadamiać o nowych aktualizacjach?"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(tr("Wega sprawdza w tle i może dać znać, gdy pojawi się coś nowego. macOS zapyta o zgodę tylko raz."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(tr("Nie teraz")) { agent.declineNotifications() }
                Button(tr("Powiadamiaj")) { Task { await agent.agreeToNotifications() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaHoney)
                    .foregroundStyle(Color.wegaInk)
            }
            .padding(12)
            .background(Color.wegaHoney.opacity(0.06))
        }
    }
}

// MARK: - Status footer

/// Persistent, window-wide footer showing scan freshness and update/security counts.
/// Visible on every tab (lives in `ContentArea`'s outer VStack, below the tab body).
private struct StatusFooter: View {
    let lastCheck:     Date?
    let updateCount:   Int
    let securityCount: Int

    private var freshnessText: String {
        if let lastCheck {
            return trf("Sprawdzono %@", "\(lastCheck.formatted(date: .omitted, time: .shortened))")
        }
        return tr("Jeszcze nie sprawdzano")
    }

    var body: some View {
        HStack(spacing: 12) {
            PawPrint(size: 11, color: Color.wegaToffee)
            Text(freshnessText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            Text(trf("%@ do aktualizacji", "\(updateCount)"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            if securityCount > 0 {
                Label(trf("%@ poprawki bezp.", "\(securityCount)"), systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.wegaDanger)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 16)
        .background(Color.wegaHoney.opacity(0.02))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

/// The right-hand column: banners, the tab body, the mascot's bubble, and the status footer.
///
/// Extracted from the old `ContentArea`, minus the 44 pt strip that imitated a toolbar —
/// `.navigationTitle` and `.navigationSubtitle` carry its label and hint now.
struct DetailColumn: View {
    let selection: SidebarSelection
    @Binding var wegaState:         WegaState
    @Binding var updateBadge:       Int
    @Binding var updateActivity:    UpdateActivity
    @Binding var logsInitialFilter: LogLevelFilter
    @Binding var logsErrorBadge:    Int
    @Binding var lastCheck:         Date?
    @Binding var securityBadge:     Int
    @Binding var appsBadge:         Int
    @Binding var cliBadge:          Int
    @Binding var brewInstalled:     Bool
    let onNavigate: (SidebarSelection) -> Void

    @State private var quip: String? = nil

    private let quips: [String] = [
        tr("Wszystko pod kontrolą!"),
        tr("Kiedy ostatnio robiłeś backup?"),
        tr("Brew to mój najlepszy przyjaciel."),
        tr("Wącham coś ciekawego…"),
        tr("Dobra robota dzisiaj!"),
        tr("Czy macOS jest aktualny?"),
        tr("Mam oko na ten dysk."),
        tr("Hau! Nowe paczki?"),
        tr("Zostań chwilę, sprawdzam…"),
        tr("Stary cask to zły cask.")
    ]

    var body: some View {
        tabBody
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { banners }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusFooter(
                    lastCheck:     lastCheck,
                    updateCount:   updateBadge,
                    securityCount: securityBadge
                )
            }
            .overlay(alignment: .bottom) {
                if let quip {
                    WegaSpeechBubble(text: quip)
                        .padding(.bottom, 24)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)),
                            removal:   .opacity
                        ))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.72), value: quip != nil)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 18...40)))
                    withAnimation { quip = quips.randomElement() }
                    try? await Task.sleep(for: .seconds(4.5))
                    withAnimation { quip = nil }
                }
            }
    }

    /// F4 — Homebrew's absence is an invitation, not a wall. The card sits above the working UI
    /// rather than in front of it. It is scoped to this column so it cannot cut across the
    /// sidebar and toolbar glass.
    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if !brewInstalled {
                BrewInviteCard { brewInstalled = BinaryLocator().locateBrew() != nil }
            }
            NotificationExplanationCard()
        }
    }

    // UpdateView stays mounted for the whole session (just hidden when another destination is
    // active) instead of being swapped in/out by the `switch`. A `switch` removes the inactive
    // view from the tree, which tears down its `@State` and orphans any in-flight `Task` — so a
    // running scan would vanish and its results reset on every tab change. Keeping it alive lets
    // the user launch a check, jump elsewhere while it keeps scanning in the background, and
    // come back to the same (still-running or finished) results. The other destinations own no
    // long-running work, so they stay mount-on-demand.
    //
    // This arrangement survived the NavigationSplitView rewrite deliberately. Replacing the
    // ZStack with a `switch` over `selection` reintroduces exactly that bug.
    @ViewBuilder
    private var tabBody: some View {
        ZStack {
            UpdateView(
                onWegaState:   { wegaState = $0 },
                onBadgeChange: { updateBadge = $0 },
                onNavigate:    { tab in
                    if tab == .logs { logsInitialFilter = .errorsOnly; logsErrorBadge = 0 }
                    onNavigate(SidebarSelection.forTab(tab))
                },
                onErrorCount:  { logsErrorBadge = $0 },
                onActivity:    { updateActivity = $0 },
                onFooterInfo:  { lastCheck = $0; securityBadge = $1 },
                updateFilter:  selection.filter ?? .all,
                onCategoryCounts: { appsBadge = $0; cliBadge = $1 }
            )
            .opacity(selection.tab == .update ? 1 : 0)
            .allowsHitTesting(selection.tab == .update)
            .accessibilityHidden(selection.tab != .update)

            if selection.tab != .update {
                switch selection {
                case .updates:
                    EmptyView()   // shown by the always-mounted UpdateView above
                case .uninstall:
                    UninstallView(onWegaState: { wegaState = $0 })
                case .migration:
                    MigrationView(onWegaState: { wegaState = $0 })
                case .inventory:
                    InventoryView(onWegaState: { wegaState = $0 })
                case .logs:
                    LogsView(onWegaState: { wegaState = $0 }, initialFilter: logsInitialFilter)
                        .id(logsInitialFilter)
                }
            }
        }
    }
}
