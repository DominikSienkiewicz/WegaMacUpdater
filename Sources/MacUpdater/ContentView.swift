import SwiftUI
import MacUpdaterCore

// MARK: - Tab definition

/// The coarse destination, still spoken by `WegaState.forTab(_:)` and `UpdateView.onNavigate`.
/// `SidebarSelection` is the finer navigation coordinate the window actually selects on, and it
/// owns the sidebar's own `label` and `systemImage`; only `hint` is still read from here, via
/// `SidebarSelection.hint`.
enum SidebarTab: String, Identifiable {
    case update    = "update"
    case uninstall = "uninstall"
    case migration = "migration"
    case inventory = "inventory"
    case logs      = "logs"

    var id: String { rawValue }

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
    @State private var showInspector: Bool  = true
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
            // Fixed, not a range: with a min/ideal/max the split view re-solved the sidebar
            // width against the detail column's changing content and shifted it left during a
            // scan, clipping the section headers. A single value pins it so the sidebar looks
            // identical whatever the detail shows.
            .navigationSplitViewColumnWidth(240)
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
                showInspector:     $showInspector,
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
                ToolbarItem(placement: .primaryAction) {
                    Button { showInspector.toggle() } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help(tr("Panel szczegółów"))
                    .disabled(selection.tab != .update)
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
