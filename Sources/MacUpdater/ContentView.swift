import SwiftUI
import MacUpdaterCore

// MARK: - Tab definition

/// The coarse destination, still spoken by `WegaState.forTab(_:)` and `UpdateView.onNavigate`.
/// `SidebarSelection` is the finer navigation coordinate the window actually selects on, and it
/// owns the sidebar's own `label` and `systemImage`; only `hint` is still read from here, via
/// `SidebarSelection.hint`.
enum SidebarTab: String, Identifiable {
    case update    = "update"
    case rollback  = "rollback"
    case uninstall = "uninstall"
    case cleanup   = "cleanup"
    case migration = "migration"
    case inventory = "inventory"
    case logs      = "logs"

    var id: String { rawValue }

    var hint: String {
        switch self {
        case .update:    return tr("Co do odświeżenia")
        case .rollback:  return tr("Co da się cofnąć")
        case .uninstall: return tr("Usuń aplikacje")
        case .cleanup:   return tr("Duplikaty i pozostałości")
        case .migration: return tr("Przepnij pod Brew")
        case .inventory: return tr("Pełny obchód")
        case .logs:      return tr("Co się działo")
        }
    }
}

/// Live state of the Updates tab, surfaced on its sidebar icon: the icon spins while a
/// scan/upgrade runs, turns green when it finishes cleanly, red when a source failed.
enum UpdateActivity: Equatable {
    case idle, scanning, updating, success, error

    /// The two states that keep working in the background and so spin the sidebar icon.
    var spinsContinuously: Bool { self == .scanning || self == .updating }
}

// MARK: - Root view

struct ContentView: View {
    /// Presenting a native inspector during the window's first layout pass can make AppKit
    /// recursively invalidate `NavigationSplitView` constraints and abort the process.
    static let showsInspectorAtLaunch = false

    /// Persisted so a language switch (which re-keys the view tree) doesn't bounce the user off
    /// their current destination — and the last one is restored on next launch.
    @AppStorage(SidebarSelection.storageKey) private var selection: SidebarSelection = .initial
    /// The pre-macOS-26 key. Read once by `migrateLegacyTab()`, then cleared.
    @AppStorage("wega.activeTab") private var legacyTab: String = ""

    /// Drives the toolbar's globe menu. Injected at the scene root (`MacUpdaterApp.swift`),
    /// which also re-keys this tree on change — so the switch takes effect everywhere at once.
    @EnvironmentObject private var localization: LocalizationManager
    @Environment(\.openWindow) private var openWindow

    @State private var wegaState:         WegaState       = .forTab(.update)
    @State private var updateBadge:       Int             = 0
    @State private var logsInitialFilter: LogLevelFilter  = .all
    @State private var logsErrorBadge:    Int             = 0
    @State private var updateActivity:    UpdateActivity  = .idle
    @State private var updateProgress:    UpgradeProgress?
    /// F4 — informational, not a gate: drives the "install Homebrew" invitation card.
    @State private var brewInstalled: Bool
    @State private var lastCheck:     Date? = nil
    /// UX-15 — Wega's comment on a scan that just finished: set by `DetailColumn`, which
    /// observes the scan, and shown by the sidebar's card.
    @State private var quip:          String? = nil
    @State private var securityBadge: Int   = 0
    @State private var appsBadge:     Int   = 0
    @State private var cliBadge:      Int   = 0
    /// LT-01 — how many updates still have a retained snapshot. Fed by `UpdateView`'s sink
    /// rather than read off `ScanStore` here: observing the store from the window's root
    /// would re-evaluate this body on every publish during a scan, and this split view is
    /// deliberately kept still (see the fixed sidebar width below).
    @State private var rollbackBadge: Int   = 0
    /// Owned by `WegaMacUpdaterApp`, above `.id(localization.language)`, so switching language
    /// re-keys this view without closing a panel the user deliberately opened. Not `@AppStorage`:
    /// a persisted `true` would present the inspector during first layout — see
    /// `showsInspectorAtLaunch`.
    @Binding private var showInspector: Bool
    /// D5 — one namespace for the toolbar's scan control, so `.glassEffectID` can morph
    /// glass between its ready and checking states.
    @Namespace private var glassNamespace

    init(showInspector: Binding<Bool>) {
        _showInspector = showInspector
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
                rollbackBadge:  rollbackBadge,
                updateActivity: updateActivity,
                updateProgress: updateProgress,
                wegaState:      wegaState,
                lastCheck:      lastCheck,
                quip:           quip
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
                updateProgress:    $updateProgress,
                logsInitialFilter: $logsInitialFilter,
                logsErrorBadge:    $logsErrorBadge,
                lastCheck:         $lastCheck,
                quip:              $quip,
                securityBadge:     $securityBadge,
                appsBadge:         $appsBadge,
                cliBadge:          $cliBadge,
                rollbackBadge:     $rollbackBadge,
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
                    Menu {
                        Picker(tr("Język interfejsu"), selection: $localization.language) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text("\(lang.flag)  \(lang.displayName)").tag(lang)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "globe")
                    }
                    .help(tr("Język interfejsu"))
                    .accessibilityLabel(tr("Język interfejsu"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showInspector.toggle() } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help(tr("Panel szczegółów"))
                    .accessibilityLabel(tr("Panel szczegółów"))
                    .disabled(selection.tab != .update)
                    // UX-16 — gone, not dimmed, outside Updates. Faded rather than removed so
                    // the toolbar item keeps its width: a toolbar whose geometry changes can
                    // invalidate the window's safe area (see `ScanControl`).
                    .opacity(selection.tab == .update ? 1 : 0)
                    .accessibilityHidden(selection.tab != .update)
                }
            }
        }
        // Deliberately no `.background(...)`. An opaque window background would leave every
        // glass surface beneath it refracting a solid rectangle, and the material would vanish.
        .frame(minWidth: WegaLayout.windowMinWidth, minHeight: WegaLayout.windowMinHeight)
        .onChange(of: selection) { _, new in wegaState = .forTab(new.tab) }
        .task { migrateLegacyTab() }
        // I1 — a second registration beside `MenuBarLabel`'s, so a notification click can
        // reopen a closed window even if the menu-bar label never appeared.
        .onAppear { NotificationRouter.shared.openMainWindow = { openWindow(id: "main") } }
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
