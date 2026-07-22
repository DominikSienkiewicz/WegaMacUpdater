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
/// Visible on every tab (attached via `DetailColumn`'s `.safeAreaInset(edge: .bottom)`).
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
        .glassEffect()
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
    @Binding var showInspector:    Bool
    let onNavigate: (SidebarSelection) -> Void

    @EnvironmentObject private var scan: ScanStore

    @State private var quip: String? = nil
    /// Cancelled and replaced (never left to race) whenever a new quip starts, so a scan
    /// that finishes while the previous bubble is still showing cannot clear it early or
    /// leave it stuck once the new sleep completes.
    @State private var quipTask: Task<Void, Never>?

    /// `.inspector` is attached unconditionally so the detail column is not rebuilt on every
    /// destination change, but it only presents on Updates: `InspectorPane`'s empty state
    /// ("pick an update") is meaningless on Logs or Inventory.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { showInspector && selection.tab == .update },
            set: { showInspector = $0 }
        )
    }

    var body: some View {
        // `NavigationSplitView` asks this root for the detail column's min/max constraints.
        // The scan states have very different intrinsic sizes; publishing those changes while
        // the native split view is resolving its children can create an AppKit constraint loop.
        // GeometryReader accepts the split view's proposal and keeps this boundary stable while
        // the content, safe-area insets, and toolbar update inside it.
        GeometryReader { _ in
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
        }
            .inspector(isPresented: inspectorPresented) {
                InspectorPane(
                    update: scan.inspectedUpdate,
                    busyToken: scan.manualBusy,
                    onInstall: { token in Task { await scan.installManual(token: token) } },
                    caskDownloads: scan.caskDownloads
                )
                .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
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
            .onReceive(scan.$inspectedKey) { key in
                guard key != nil else { return }
                showInspector = true
            }
            .onChange(of: scan.status) { old, new in
                // A cancelled scan also lands on `.results` (ScanStore.bailIfCancelled), so the
                // status transition alone is not enough — only a finished scan earns a comment.
                guard old == .checking, new == .results, scan.progress == .finished else { return }
                quipTask?.cancel()
                withAnimation { quip = finishedQuip() }
                quipTask = Task {
                    try? await Task.sleep(for: .seconds(4.5))
                    guard !Task.isCancelled else { return }
                    withAnimation { quip = nil }
                }
            }
    }

    /// Wega comments on the result, not on the clock. Security wins over the update count:
    /// a pending security fix still gets flagged even when it happens to be the only item,
    /// which would otherwise round `updateBadge` down to a false "all clear".
    private func finishedQuip() -> String {
        if securityBadge > 0 { return tr("Znalazłam coś pilnego.") }
        if updateBadge == 0  { return tr("Wszystko pod kontrolą!") }
        return tr("Hau! Nowe paczki?")
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
