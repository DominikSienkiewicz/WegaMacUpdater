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
        // UX-15 — an invitation, so the callout's info level; the recheck is no longer drawn
        // as a prominent button, which belongs to the update itself.
        WegaCallout(
            .info,
            title: tr("Zainstaluj Homebrew, żeby odblokować więcej aktualizacji"),
            message: tr("Wega działa bez niego — sprawdza Mac App Store, Sparkle, feedy producentów i npm. Homebrew dokłada formuły i caski."),
            symbol: "shippingbox.fill"
        ) {
            Text(installCommand)
                .font(.wega(.footnote, monospaced: true))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
        } actions: {
            Button(copied ? tr("Skopiowano") : tr("Kopiuj polecenie")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(installCommand, forType: .string)
                copied = true
            }
            Button(tr("Sprawdź ponownie"), action: onRecheck)
        }
        .padding(.horizontal, WegaLayout.listGutter)
        .padding(.top, 8)
    }
}

/// The right-hand column: banners and the tab body. Wega's lines, the scan's freshness and
/// the notification question live in the sidebar's `WegaCompanionCard` (UX-15).
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
    /// UX-15 — written here, where the scan is observed, and shown by the sidebar's card.
    @Binding var quip:              String?
    @Binding var securityBadge:     Int
    @Binding var appsBadge:         Int
    @Binding var cliBadge:          Int
    @Binding var rollbackBadge:     Int
    @Binding var brewInstalled:     Bool
    @Binding var showInspector:    Bool
    let onNavigate: (SidebarSelection) -> Void

    @EnvironmentObject private var scan: ScanStore

    /// Cancelled and replaced (never left to race) whenever a new quip starts, so a scan
    /// that finishes while the previous comment is still showing cannot clear it early or
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
            .onReceive(scan.$inspectedKey) { key in
                guard key != nil else { return }
                showInspector = true
            }
            .onChange(of: scan.status) { old, new in
                // A cancelled scan also lands on `.results` (ScanStore.bailIfCancelled), so the
                // status transition alone is not enough — only a finished scan earns a comment.
                guard old == .checking, new == .results, scan.progress == .finished else { return }
                quipTask?.cancel()
                quip = WegaCompanionPresentation.finishedQuip(updateCount: updateBadge, securityCount: securityBadge,
                                                                  scanComplete: scan.lastScanComplete)
                quipTask = Task {
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    quip = nil
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
                onCategoryCounts: { appsBadge = $0; cliBadge = $1 },
                onUndoableCount:  { rollbackBadge = $0 },
                onScopeChange:    { onNavigate(.updates($0)) },
                wegaLine: quip ?? wegaState.line
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
                case .cleanup:
                    CleanupView(onWegaState: { wegaState = $0 })
                case .migration:
                    MigrationView(onWegaState: { wegaState = $0 })
                case .inventory:
                    InventoryView(onWegaState: { wegaState = $0 })
                case .rollback:
                    RollbackView()
                case .logs:
                    LogsView(onWegaState: { wegaState = $0 }, initialFilter: logsInitialFilter)
                        .id(logsInitialFilter)
                }
            }
        }
    }
}
