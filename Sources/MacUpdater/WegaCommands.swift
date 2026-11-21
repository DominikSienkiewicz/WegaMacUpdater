import SwiftUI
import MacUpdaterCore

// MARK: - UX-10 — pozycje menu i skróty klawiaturowe
//
// Before UX-10 the app defined no `.commands` at all: the only way to start a scan was the
// toolbar button, and none of the destinations had a keyboard shortcut. This file adds the
// menu bar commands and their macOS-conventional shortcuts (⌘R, ⌘⏎, ⌘., ⌘1…⌘7, ⌘F, ⇧⌘F,
// ⇧⌘A, ⌥⌘I) and the Help menu's user guide.
//
// Scan and update actions are published *from the view tree* as `WegaMenuAction`s, so a menu
// shortcut is greyed out in exactly the situations its on-screen control is (a shortcut that
// silently no-ops reads as a bug). Navigation writes the same `@AppStorage` selection the
// sidebar binds to, so ⌘1…⌘7 and a sidebar click are the one code path. ⌘F and ⇧⌘F reach the
// screens' existing search fields through `WegaCommandCenter`.

/// A menu-invocable action mirrored from the window's view tree. `isEnabled` tracks the
/// equivalent on-screen control; `run` performs the action. `run` is `@MainActor` because it
/// drives main-actor UI state (the scan store, the update confirmation).
struct WegaMenuAction {
    let isEnabled: Bool
    let run: @MainActor () -> Void
}

extension WegaMenuAction {
    /// The first of `actions` that can run now, or `nil` when none can — for one menu item that
    /// stands for several actions in order of precedence (⌘.).
    static func firstEnabled(_ actions: WegaMenuAction?...) -> WegaMenuAction? {
        actions.lazy.compactMap { $0 }.first { $0.isEnabled }
    }
}

/// UXP-23 — ⌘. is one item for the two things that can be stopped. While an update runs the
/// item is the run's, in the words its own stop button uses, also once the stop is requested
/// and the item is disabled; otherwise the item cancels the scan.
enum CancelCommandCopy {
    static func title(run: UpdateRunCommandState) -> String {
        switch run {
        case .idle:     return tr("Anuluj skan")
        case .running:  return UpdateRunCopy.stopLabel(isStopping: false)
        case .stopping: return UpdateRunCopy.stopLabel(isStopping: true)
        }
    }
}

/// Where the window's update run is, for the menu: none, running, or asked to stop.
enum UpdateRunCommandState: Equatable {
    case idle, running, stopping

    init(isUpdating: Bool, isStopping: Bool) {
        guard isUpdating else { self = .idle; return }
        self = isStopping ? .stopping : .running
    }
}

private struct StartCheckActionKey: FocusedValueKey { typealias Value = WegaMenuAction }
private struct RunUpdateActionKey: FocusedValueKey { typealias Value = WegaMenuAction }
private struct StopUpdateActionKey: FocusedValueKey { typealias Value = WegaMenuAction }
private struct CancelScanActionKey: FocusedValueKey { typealias Value = WegaMenuAction }
private struct SelectAllVisibleActionKey: FocusedValueKey { typealias Value = WegaMenuAction }
private struct ToggleInspectorActionKey: FocusedValueKey { typealias Value = WegaMenuAction }
private struct UpdateRunCommandStateKey: FocusedValueKey { typealias Value = UpdateRunCommandState }

extension FocusedValues {
    /// ⌘R — the window's "Sprawdź teraz". Published by `UpdateView`, which owns the scan store.
    var startCheckAction: WegaMenuAction? {
        get { self[StartCheckActionKey.self] }
        set { self[StartCheckActionKey.self] = newValue }
    }

    /// ⌘⏎ — the window's "Aktualizuj". Opens the same confirmation the toolbar button does,
    /// rather than mutating the system straight from a keystroke.
    var runUpdateAction: WegaMenuAction? {
        get { self[RunUpdateActionKey.self] }
        set { self[RunUpdateActionKey.self] = newValue }
    }

    /// ⌘. — stops the running update after the installs already started. Published by
    /// `DetailColumn` only while a run is going and has not been asked to stop.
    var stopUpdateAction: WegaMenuAction? {
        get { self[StopUpdateActionKey.self] }
        set { self[StopUpdateActionKey.self] = newValue }
    }

    /// ⌘. while no update runs — cancels the scan the store is running, like the toolbar's
    /// "Anuluj". Published by `UpdateView`, which stays mounted on every screen.
    var cancelScanAction: WegaMenuAction? {
        get { self[CancelScanActionKey.self] }
        set { self[CancelScanActionKey.self] = newValue }
    }

    /// ⇧⌘A — queues every row the Updates list shows, under the list's own selection gate.
    var selectAllVisibleAction: WegaMenuAction? {
        get { self[SelectAllVisibleActionKey.self] }
        set { self[SelectAllVisibleActionKey.self] = newValue }
    }

    /// ⌥⌘I — the toolbar's inspector button, on the screen where that button is offered.
    var toggleInspectorAction: WegaMenuAction? {
        get { self[ToggleInspectorActionKey.self] }
        set { self[ToggleInspectorActionKey.self] = newValue }
    }

    /// ⌘.'s title — whether an update runs and whether it was asked to stop. Published by
    /// `DetailColumn` next to `stopUpdateAction`.
    var updateRunCommandState: UpdateRunCommandState? {
        get { self[UpdateRunCommandStateKey.self] }
        set { self[UpdateRunCommandStateKey.self] = newValue }
    }
}

/// A tiny command bus for menu actions that must reach a view which is not mounted yet.
///
/// ⌘F and ⇧⌘F ask a screen's search field for focus. ⇧⌘F first navigates to the inventory,
/// whose field — mounting fresh in the same turn — was not in the tree to hear a direct call.
/// The request is left pending here, per screen, and consumed on the field's appearance
/// instead. `lastConsumed` lives on this object (not on the view's `@State`) so it survives the
/// screen being torn down and rebuilt on every tab switch.
@MainActor
final class WegaCommandCenter: ObservableObject {
    /// Bumped per screen by ⌘F and ⇧⌘F. Monotonic, so a repeat request while already on the
    /// screen still trips the view's `.onChange`.
    @Published private(set) var searchFocusRequests: [SidebarTab: Int] = [:]
    private var lastConsumed: [SidebarTab: Int] = [:]

    func requestSearchFocus(on tab: SidebarTab) {
        searchFocusRequests[tab, default: 0] += 1
    }

    /// True exactly once per request for `tab` — also on the on-appearance path, where the view
    /// missed the `.onChange` because it was not yet in the tree when the shortcut fired.
    func consumePendingSearchFocus(on tab: SidebarTab) -> Bool {
        let requested = searchFocusRequests[tab, default: 0]
        guard requested > lastConsumed[tab, default: 0] else { return false }
        lastConsumed[tab] = requested
        return true
    }

    func requestInventorySearchFocus() {
        requestSearchFocus(on: .inventory)
    }

    func consumePendingInventorySearchFocus() -> Bool {
        consumePendingSearchFocus(on: .inventory)
    }
}

/// Focuses a screen's `.searchable` field whenever ⌘F or ⇧⌘F asks for it: while the screen is
/// on, through `.onChange`, or on its arrival, for a request made from another screen.
private struct SearchFocusRequestReceiver: ViewModifier {
    let tab: SidebarTab
    let focus: () -> Void

    @EnvironmentObject private var commandCenter: WegaCommandCenter

    func body(content: Content) -> some View {
        content
            .onAppear(perform: focusIfRequested)
            .onChange(of: commandCenter.searchFocusRequests[tab]) { _, _ in focusIfRequested() }
    }

    private func focusIfRequested() {
        guard commandCenter.consumePendingSearchFocus(on: tab) else { return }
        // A field that is only just appearing needs a runloop tick before it accepts focus.
        Task { @MainActor in focus() }
    }
}

extension View {
    /// See `SearchFocusRequestReceiver`. Attach it to the view that carries `.searchable`.
    func receivesSearchFocusRequests(on tab: SidebarTab, focus: @escaping () -> Void) -> some View {
        modifier(SearchFocusRequestReceiver(tab: tab, focus: focus))
    }
}

/// The ⌘1…⌘7 destinations, in sidebar order: the coarse sections, top to bottom. The Updates
/// section opens on its unfiltered list; its category sub-filters keep their place in the
/// sidebar but are not each given a number.
///
/// „Cofnij aktualizacje” takes ⌘4 by sitting where it sits in the sidebar, which pushes
/// Uninstall and Logs down a digit. The numbers follow the sidebar rather than the other way
/// round: a menu that skipped a visible destination would be the worse surprise.
enum WegaMenuNavigation {
    static let numberedDestinations: [SidebarSelection] = [
        .updates(.all),   // ⌘1
        .migration,       // ⌘2
        .inventory,       // ⌘3
        .rollback,        // ⌘4
        .uninstall,       // ⌘5
        .cleanup,         // ⌘6
        .logs,            // ⌘7
    ]
}

/// UX-10 — the app's menu bar commands. Every shortcut of the window (⌘R, ⌘⏎, ⌘., ⌘F, ⇧⌘F,
/// ⇧⌘A, ⌥⌘I, ⌘1…⌘7) lives in this one `CommandMenu` so it reads as a single, discoverable place.
struct WegaCommands: Commands {
    let commandCenter: WegaCommandCenter

    @AppStorage("wega.sidebarSelection") private var selection: SidebarSelection = .initial
    @FocusedValue(\.startCheckAction) private var startCheck
    @FocusedValue(\.runUpdateAction) private var runUpdate
    @FocusedValue(\.stopUpdateAction) private var stopUpdate
    @FocusedValue(\.updateRunCommandState) private var updateRun
    @FocusedValue(\.cancelScanAction) private var cancelScan
    @FocusedValue(\.selectAllVisibleAction) private var selectAllVisible
    @FocusedValue(\.toggleInspectorAction) private var toggleInspector
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    // Explicit initializer: the synthesized memberwise one inherits the `private` of the
    // property wrappers above and so cannot be called from `MacUpdaterApp`.
    init(commandCenter: WegaCommandCenter) {
        self.commandCenter = commandCenter
    }

    var body: some Commands {
        // macOS convention: an app's own update check lives in the app menu, right under About.
        // The item opens the Settings window, where the self-update screen owns the operation.
        CommandGroup(after: .appInfo) {
            Button(tr("Sprawdź aktualizacje Wegi…")) { SettingsRoute.shared.open(.selfUpdate, with: openSettings) }
        }

        CommandMenu(tr("Aktualizacje")) {
            Button(tr("Sprawdź teraz")) { startCheck?.run() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(startCheck?.isEnabled != true)

            Button(tr("Aktualizuj")) { runUpdate?.run() }
                .keyboardShortcut(.return, modifiers: .command)
                // Only on the Updates destination, and only when there is something to install —
                // the same conditions under which the "Zaktualizuj…" button is offered.
                .disabled(!(selection.tab == .update && runUpdate?.isEnabled == true))

            let cancelTarget = WegaMenuAction.firstEnabled(stopUpdate, cancelScan)
            Button(CancelCommandCopy.title(run: updateRun ?? .idle)) { cancelTarget?.run() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(cancelTarget == nil)

            Divider()

            Button(tr("Zaznacz wszystkie widoczne")) { selectAllVisible?.run() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!(selection.tab == .update && selectAllVisible?.isEnabled == true))

            Button(tr("Pokaż panel szczegółów")) { toggleInspector?.run() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(toggleInspector?.isEnabled != true)

            Divider()

            Button(tr("Znajdź na tym ekranie")) { commandCenter.requestSearchFocus(on: selection.tab) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!selection.tab.hasSearchField)

            Button(tr("Znajdź w spisie aplikacji")) {
                selection = .inventory
                commandCenter.requestInventorySearchFocus()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            ForEach(Array(WegaMenuNavigation.numberedDestinations.enumerated()), id: \.offset) { item in
                Button(item.element.label) { selection = item.element }
                    .keyboardShortcut(Self.numberKey(item.offset + 1), modifiers: .command)
            }
        }

        // Replaces the default item, which only says that help is not available.
        CommandGroup(replacing: .help) {
            Button(tr("Przewodnik po Wedze")) { openURL(AppEndpoints.shared.userGuideURL) }
        }
    }

    /// The digit key for position 1…9. Built from the ASCII scalar so it needs no runtime
    /// String→Character bridging (`Character` has no `init(_: String)`).
    private static func numberKey(_ position: Int) -> KeyEquivalent {
        KeyEquivalent(Character(Unicode.Scalar(UInt8(0x30 + position))))
    }
}
