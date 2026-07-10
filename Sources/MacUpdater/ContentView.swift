import SwiftUI
import MacUpdaterCore

// MARK: - Tab definition

enum SidebarTab: String, Identifiable {
    case update    = "update"
    case uninstall = "uninstall"
    case migration = "migration"
    case inventory = "inventory"
    case logs      = "logs"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .update:    return tr("Aktualizacje")
        case .uninstall: return tr("Odinstaluj aplikacje")
        case .migration: return tr("Migracja")
        case .inventory: return tr("Spis aplikacji")
        case .logs:      return tr("Logi")
        }
    }
    var systemImage: String {
        switch self {
        case .update:    return "arrow.triangle.2.circlepath"
        case .uninstall: return "trash"
        case .migration: return "arrow.right.doc.on.clipboard"
        case .inventory: return "tablecells"
        case .logs:      return "doc.text.magnifyingglass"
        }
    }
    var hint: String {
        switch self {
        case .update:    return tr("Co do odświeżenia")
        case .uninstall: return tr("Usuń aplikacje")
        case .migration: return tr("Przepnij pod Brew")
        case .inventory: return tr("Pełny obchód")
        case .logs:      return tr("Co się działo")
        }
    }
}

/// Live state of the Updates tab, surfaced on its sidebar icon: the icon spins while a
/// scan/upgrade runs, turns green when it finishes cleanly, red when a source failed.
enum UpdateActivity: Equatable {
    case idle, scanning, success, error
}

// MARK: - Root view

struct ContentView: View {
    // Persisted so a language switch (which re-keys the view tree) doesn't bounce
    // the user off their current tab — and the last tab is restored on next launch.
    @AppStorage("wega.activeTab") private var activeTab: SidebarTab = .update
    @State private var wegaState:    WegaState  = .forTab(.update)
    @State private var updateBadge:  Int        = 0
    @State private var logsInitialFilter: LogLevelFilter = .all
    @State private var logsErrorBadge: Int = 0
    @State private var updateActivity: UpdateActivity = .idle
    /// F4 — informational, not a gate: drives the "install Homebrew" invitation card.
    @State private var brewInstalled: Bool
    @State private var lastCheck: Date? = nil
    @State private var securityBadge: Int = 0
    @State private var updateFilter: UpdateFilter = .all
    @State private var appsBadge: Int = 0
    @State private var cliBadge: Int = 0

    init() {
        _brewInstalled = State(initialValue: BinaryLocator().locateBrew() != nil)
    }

    var body: some View {
        // F4 — Homebrew is no longer a wall. Without it Wega still checks the Mac App Store,
        // Sparkle, the nine vendor feeds and npm; a card invites the user to install it
        // rather than blocking the whole app behind a Terminal command (which would
        // contradict the "zero terminal" promise in the first line of the README).
        VStack(spacing: 0) {
            if !brewInstalled {
                BrewInviteCard { brewInstalled = BinaryLocator().locateBrew() != nil }
            }
            HStack(spacing: 0) {
                    SidebarView(
                        activeTab:      $activeTab,
                        wegaState:      $wegaState,
                        updateFilter:   $updateFilter,
                        appsBadge:      appsBadge,
                        cliBadge:       cliBadge,
                        securityBadge:  securityBadge,
                        updateActivity: updateActivity,
                        logsInitialFilter: $logsInitialFilter,
                        logsErrorBadge: $logsErrorBadge
                    )
                    Divider()
                    ContentArea(
                        activeTab:   $activeTab,
                        wegaState:   $wegaState,
                        updateBadge: $updateBadge,
                        updateActivity: $updateActivity,
                        logsInitialFilter: $logsInitialFilter,
                        logsErrorBadge: $logsErrorBadge,
                        lastCheck: $lastCheck,
                        securityBadge: $securityBadge,
                        updateFilter: $updateFilter,
                        appsBadge: $appsBadge,
                        cliBadge: $cliBadge
                    )
            }
        }
        .frame(minWidth: WegaLayout.windowMinWidth, minHeight: WegaLayout.windowMinHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help(tr("Ustawienia"))
            }
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Binding var activeTab:   SidebarTab
    @Binding var wegaState:   WegaState
    @Binding var updateFilter: UpdateFilter
    let appsBadge: Int
    let cliBadge: Int
    let securityBadge: Int
    let updateActivity: UpdateActivity
    @Binding var logsInitialFilter: LogLevelFilter
    @Binding var logsErrorBadge: Int

    /// Uppercase section header — same styling the old single "Narzędzia" header used.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(1)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Brand header
            HStack(spacing: 11) {
                WegaIcon(size: 36, radius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WegaMacUpdater")
                        .font(.system(size: 14, weight: .bold))
                    HelperChip()
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)

            Divider().opacity(0.5)

            // Tab list — three sections: what needs updating, what's installed, and tools.
            VStack(alignment: .leading, spacing: 1) {
                sectionHeader(tr("Do aktualizacji"))

                SidebarItemRow(
                    label:        tr("Wszystkie"),
                    systemImage:  "arrow.triangle.2.circlepath",
                    isActive:     activeTab == .update && updateFilter == .all,
                    badge:        (appsBadge + cliBadge) > 0 ? (appsBadge + cliBadge) : nil,
                    activity:     updateActivity,
                    onSelect: {
                        activeTab = .update
                        updateFilter = .all
                        wegaState = .forTab(.update)
                    }
                )
                SidebarItemRow(
                    label:        tr("Aplikacje"),
                    systemImage:  "square.grid.2x2",
                    isActive:     activeTab == .update && updateFilter == .apps,
                    badge:        appsBadge > 0 ? appsBadge : nil,
                    onSelect: {
                        activeTab = .update
                        updateFilter = .apps
                        wegaState = .forTab(.update)
                    }
                )
                SidebarItemRow(
                    label:        tr("Narzędzia CLI"),
                    systemImage:  "terminal",
                    isActive:     activeTab == .update && updateFilter == .cli,
                    badge:        cliBadge > 0 ? cliBadge : nil,
                    onSelect: {
                        activeTab = .update
                        updateFilter = .cli
                        wegaState = .forTab(.update)
                    }
                )
                SidebarItemRow(
                    label:        tr("Poprawki bezp."),
                    systemImage:  "shield.lefthalf.filled",
                    isActive:     activeTab == .update && updateFilter == .security,
                    badge:        securityBadge > 0 ? securityBadge : nil,
                    badgeIsDanger: true,
                    onSelect: {
                        activeTab = .update
                        updateFilter = .security
                        wegaState = .forTab(.update)
                    }
                )

                sectionHeader(tr("Zainstalowane"))

                SidebarItemRow(
                    label:        tr("Do przepięcia"),
                    systemImage:  "arrow.right.doc.on.clipboard",
                    isActive:     activeTab == .migration,
                    badge:        nil,
                    onSelect: {
                        activeTab = .migration
                        wegaState = .forTab(.migration)
                    }
                )
                SidebarItemRow(
                    label:        tr("Spis aplikacji"),
                    systemImage:  "tablecells",
                    isActive:     activeTab == .inventory,
                    badge:        nil,
                    onSelect: {
                        activeTab = .inventory
                        wegaState = .forTab(.inventory)
                    }
                )

                sectionHeader(tr("Narzędzia"))

                SidebarItemRow(
                    label:        tr("Odinstaluj aplikacje"),
                    systemImage:  "trash",
                    isActive:     activeTab == .uninstall,
                    badge:        nil,
                    onSelect: {
                        activeTab = .uninstall
                        wegaState = .forTab(.uninstall)
                    }
                )
                SidebarItemRow(
                    label:        tr("Logi"),
                    systemImage:  "doc.text.magnifyingglass",
                    isActive:     activeTab == .logs,
                    badge:        logsErrorBadge > 0 ? logsErrorBadge : nil,
                    badgeIsDanger: true,
                    onSelect: {
                        logsInitialFilter = .all
                        logsErrorBadge = 0
                        activeTab = .logs
                        wegaState = .forTab(.logs)
                    }
                )
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Spacer()
        }
        .frame(width: WegaLayout.sidebarWidth)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }
}

private struct SidebarItemRow: View {
    let label:        String
    let systemImage:  String
    let isActive:     Bool
    let badge:        Int?
    var badgeIsDanger: Bool = false
    var activity:     UpdateActivity = .idle
    let onSelect:     () -> Void

    @State private var isHovered = false
    @State private var rotation: Double = 0

    /// Row fill: active wins, otherwise a faint tint on hover.
    private var backgroundFill: Color {
        if isActive { return Color.wegaHoney.opacity(0.15) }
        return isHovered ? Color.wegaHoney.opacity(0.05) : Color.clear
    }

    /// Badge foreground/background — danger (logs) wins, then active vs. idle. Extracted
    /// from the body so it isn't a nested ternary (Sonar S3358).
    private func badgeColors() -> (fg: Color, bg: Color) {
        if badgeIsDanger {
            return (.white, Color.wegaDanger)
        }
        if isActive {
            return (Color.wegaInk, Color.wegaHoney)
        }
        return (Color.wegaHoney, Color.wegaHoney.opacity(0.18))
    }

    /// Icon tint — scan activity (green ok / red error) overrides the active/idle colour.
    private var iconColor: Color {
        switch activity {
        case .scanning: return Color.wegaHoney
        case .success:  return Color.wegaSuccess
        case .error:    return Color.wegaDanger
        case .idle:     return isActive ? Color.wegaHoney : .secondary
        }
    }

    /// Continuous spin while scanning; ease back to rest otherwise.
    private func spin(for activity: UpdateActivity) {
        if activity == .scanning {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { rotation = 0 }
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(iconColor)
                    .rotationEffect(.degrees(rotation))
                    .frame(width: 16)
                    .animation(.easeInOut(duration: 0.25), value: iconColor)
                    .onChange(of: activity) { _, new in spin(for: new) }
                    .onAppear { spin(for: activity) }
                Text(label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                Spacer()
                if let b = badge {
                    let colors = badgeColors()
                    Text("\(b)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(colors.fg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(colors.bg, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(backgroundFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isActive ? Color.wegaHoney.opacity(0.20) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

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

private struct WegaSpeechBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            PawPrint(size: 10, color: Color.wegaHoney)
            Text(text)
                .font(.system(size: 11.5).italic())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.30), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Helper chip

/// M3(a) — reports the privileged helper's real `SMAppService` status instead of a
/// hard-coded green dot. Re-reads the status when the app comes back to the front, since
/// approval happens outside our process (System Settings → Login Items).
private struct HelperChip: View {
    @State private var state = HelperChipState(status: PrivilegedHelperClient.shared.status)

    private var color: Color {
        switch state {
        case .active:        return .wegaSuccess
        case .needsApproval: return .wegaHoney
        case .inactive:      return .secondary
        }
    }

    private var label: String {
        switch state {
        case .active:        return tr("brew · helper aktywny")
        case .needsApproval: return tr("brew · helper wymaga zgody")
        case .inactive:      return tr("brew · helper nieaktywny")
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if state.opensLoginItemsSettings { PrivilegedHelperClient.shared.openLoginItemsSettings() }
        }
        .accessibilityLabel(label)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state = HelperChipState(status: PrivilegedHelperClient.shared.status)
        }
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

// MARK: - Content area

private struct ContentArea: View {
    @Binding var activeTab:   SidebarTab
    @Binding var wegaState:   WegaState
    @Binding var updateBadge: Int
    @Binding var updateActivity: UpdateActivity
    @Binding var logsInitialFilter: LogLevelFilter
    @Binding var logsErrorBadge: Int
    @Binding var lastCheck: Date?
    @Binding var securityBadge: Int
    @Binding var updateFilter: UpdateFilter
    @Binding var appsBadge: Int
    @Binding var cliBadge: Int

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
        tr("Stary cask to zły cask."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: activeTab.systemImage)
                    .foregroundStyle(Color.wegaHoney)
                Text(activeTab.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(trf("· %@", "\(activeTab.hint)"))
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 6) {
                    PawPrint(size: 12, color: Color.wegaToffee)
                    Text(wegaState.line)
                        .font(.system(size: 11).italic())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color.wegaHoney.opacity(0.02))

            Divider().opacity(0.5)

            NotificationExplanationCard()

            // Tab body.
            //
            // UpdateView stays mounted for the whole session (just hidden when another
            // tab is active) instead of being swapped in/out by the `switch`. A `switch`
            // removes the inactive view from the tree, which tears down its `@State` and
            // orphans any in-flight `Task` — so a running scan would vanish and its
            // results reset on every tab change. Keeping it alive lets the user launch a
            // check, jump to another tab while it keeps scanning in the background, and
            // come back to the same (still-running or finished) results. The other tabs
            // own no long-running work, so they stay mount-on-demand.
            ZStack {
                UpdateView(
                    onWegaState:   { wegaState = $0 },
                    onBadgeChange: { updateBadge = $0 },
                    onNavigate:    { tab in
                        if tab == .logs { logsInitialFilter = .errorsOnly; logsErrorBadge = 0 }
                        activeTab = tab
                        wegaState = .forTab(tab)
                    },
                    onErrorCount:  { logsErrorBadge = $0 },
                    onActivity:    { updateActivity = $0 },
                    onFooterInfo:  { lastCheck = $0; securityBadge = $1 },
                    updateFilter:  updateFilter,
                    onCategoryCounts: { appsBadge = $0; cliBadge = $1 }
                )
                .opacity(activeTab == .update ? 1 : 0)
                .allowsHitTesting(activeTab == .update)
                .accessibilityHidden(activeTab != .update)

                if activeTab != .update {
                    Group {
                        switch activeTab {
                        case .update:
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusFooter(lastCheck: lastCheck, updateCount: updateBadge, securityCount: securityBadge)
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
