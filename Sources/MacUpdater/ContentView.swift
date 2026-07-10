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
    /// Persisted so a language switch (which re-keys the view tree) doesn't bounce the user off
    /// their current destination — and the last one is restored on next launch.
    @AppStorage("wega.sidebarSelection") private var selection: SidebarSelection = .default
    /// The pre-macOS-26 key. Read once by `migrateLegacyTab()`, then cleared.
    @AppStorage("wega.activeTab") private var legacyTab: String = ""

    @State private var wegaState:         WegaState       = .forTab(.update)
    @State private var updateBadge:       Int             = 0
    @State private var logsInitialFilter: LogLevelFilter  = .all
    @State private var logsErrorBadge:    Int             = 0
    @State private var updateActivity:    UpdateActivity  = .idle
    /// F4 — informational, not a gate: drives the "install Homebrew" invitation card.
    @State private var brewInstalled: Bool
    @State private var lastCheck:     Date? = nil
    @State private var securityBadge: Int   = 0
    @State private var appsBadge:     Int   = 0
    @State private var cliBadge:      Int   = 0
    /// D5 — one namespace for the toolbar's scan control, so `.glassEffectID` can morph
    /// glass between its ready and checking states.
    @Namespace private var glassNamespace

    init() {
        _brewInstalled = State(initialValue: BinaryLocator().locateBrew() != nil)
    }

    var body: some View {
        NavigationSplitView {
            SidebarList(
                selection:      $selection,
                appsBadge:      appsBadge,
                cliBadge:       cliBadge,
                securityBadge:  securityBadge,
                logsErrorBadge: logsErrorBadge,
                updateActivity: updateActivity
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            DetailColumn(
                selection:         selection,
                wegaState:         $wegaState,
                updateBadge:       $updateBadge,
                updateActivity:    $updateActivity,
                logsInitialFilter: $logsInitialFilter,
                logsErrorBadge:    $logsErrorBadge,
                lastCheck:         $lastCheck,
                securityBadge:     $securityBadge,
                appsBadge:         $appsBadge,
                cliBadge:          $cliBadge,
                brewInstalled:     $brewInstalled,
                onNavigate:        { selection = $0 }
            )
            .navigationTitle(selection.label)
            .navigationSubtitle(selection.hint)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ScanControl(namespace: glassNamespace)
                }
                ToolbarSpacer(.fixed)
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink { Image(systemName: "gearshape") }
                        .help(tr("Ustawienia"))
                }
            }
        }
        // Deliberately no `.background(...)`. An opaque window background would leave every
        // glass surface beneath it refracting a solid rectangle, and the material would vanish.
        .frame(minWidth: WegaLayout.windowMinWidth, minHeight: WegaLayout.windowMinHeight)
        .onChange(of: selection) { _, new in wegaState = .forTab(new.tab) }
        .task { migrateLegacyTab() }
    }

    /// One-shot migration off `wega.activeTab`, which stored only the tab and never the Updates
    /// filter — so `update` restores the unfiltered list. Unknown or absent values fall through
    /// to the `@AppStorage` default.
    private func migrateLegacyTab() {
        guard !legacyTab.isEmpty else { return }
        if let migrated = SidebarSelection.migrating(legacyTab: legacyTab) {
            selection = migrated
        }
        legacyTab = ""
    }
}
