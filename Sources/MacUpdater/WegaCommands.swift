import SwiftUI
import MacUpdaterCore

// MARK: - UX-10 — pozycje menu i skróty klawiaturowe
//
// Before UX-10 the app defined no `.commands` at all: the only way to start a scan was the
// toolbar button, and none of the destinations had a keyboard shortcut. This file adds the
// menu bar commands and their macOS-conventional shortcuts (⌘R, ⌘⏎, ⌘1…⌘5, ⌘F).
//
// Scan and update actions are published *from the view tree* as `WegaMenuAction`s, so a menu
// shortcut is greyed out in exactly the situations its on-screen control is (a shortcut that
// silently no-ops reads as a bug). Navigation writes the same `@AppStorage` selection the
// sidebar binds to, so ⌘1…⌘5 and a sidebar click are the one code path. ⌘F reaches the
// inventory's existing search field through `WegaCommandCenter`.

/// A menu-invocable action mirrored from the window's view tree. `isEnabled` tracks the
/// equivalent on-screen control; `run` performs the action. `run` is `@MainActor` because it
/// drives main-actor UI state (the scan store, the update confirmation).
struct WegaMenuAction {
    let isEnabled: Bool
    let run: @MainActor () -> Void
}

private struct StartCheckActionKey: FocusedValueKey { typealias Value = WegaMenuAction }
private struct RunUpdateActionKey: FocusedValueKey { typealias Value = WegaMenuAction }

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
}

/// A tiny command bus for menu actions that must reach a view which is not mounted yet.
///
/// Today only ⌘F needs it: from another destination it first navigates to the inventory,
/// and the inventory's search field — mounting fresh in the same turn — was not in the tree
/// to hear a direct call. The request is left pending here and consumed on the field's
/// appearance instead. `lastConsumed` lives on this object (not on the view's `@State`) so it
/// survives the inventory being torn down and rebuilt on every tab switch.
@MainActor
final class WegaCommandCenter: ObservableObject {
    /// Bumped by ⌘F. Monotonic, so a repeat ⌘F while already on the inventory still trips the
    /// view's `.onChange`.
    @Published private(set) var inventorySearchFocusRequests = 0
    private var lastConsumed = 0

    func requestInventorySearchFocus() {
        inventorySearchFocusRequests += 1
    }

    /// True exactly once per request — for the on-appearance path, where the view missed the
    /// `.onChange` because it was not yet in the tree when ⌘F fired.
    func consumePendingInventorySearchFocus() -> Bool {
        guard inventorySearchFocusRequests > lastConsumed else { return false }
        lastConsumed = inventorySearchFocusRequests
        return true
    }
}

/// The ⌘1…⌘5 destinations, in sidebar order: the five coarse sections, top to bottom. The
/// Updates section opens on its unfiltered list; its category sub-filters keep their place in
/// the sidebar but are not each given a number.
enum WegaMenuNavigation {
    static let numberedDestinations: [SidebarSelection] = [
        .updates(.all),   // ⌘1
        .migration,       // ⌘2
        .inventory,       // ⌘3
        .uninstall,       // ⌘4
        .logs,            // ⌘5
    ]
}

/// UX-10 — the app's menu bar commands. Every shortcut the card asks for (⌘R, ⌘⏎, ⌘1…⌘5, ⌘F)
/// lives in this one `CommandMenu` so it reads as a single, discoverable place.
struct WegaCommands: Commands {
    let commandCenter: WegaCommandCenter

    @AppStorage("wega.sidebarSelection") private var selection: SidebarSelection = .initial
    @FocusedValue(\.startCheckAction) private var startCheck
    @FocusedValue(\.runUpdateAction) private var runUpdate
    @Environment(\.openSettings) private var openSettings

    // Explicit initializer: the synthesized memberwise one inherits the `private` of the
    // property wrappers above and so cannot be called from `MacUpdaterApp`.
    init(commandCenter: WegaCommandCenter) {
        self.commandCenter = commandCenter
    }

    var body: some Commands {
        // macOS convention: an app's own update check lives in the app menu, right under About.
        // The item opens the Settings window, where the self-update screen owns the operation.
        CommandGroup(after: .appInfo) {
            Button(tr("Sprawdź aktualizacje Wegi…")) { openSettings() }
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

            Divider()

            Button(tr("Znajdź w spisie aplikacji")) {
                selection = .inventory
                commandCenter.requestInventorySearchFocus()
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            ForEach(Array(WegaMenuNavigation.numberedDestinations.enumerated()), id: \.offset) { item in
                Button(item.element.label) { selection = item.element }
                    .keyboardShortcut(Self.numberKey(item.offset + 1), modifiers: .command)
            }
        }
    }

    /// The digit key for position 1…9. Built from the ASCII scalar so it needs no runtime
    /// String→Character bridging (`Character` has no `init(_: String)`).
    private static func numberKey(_ position: Int) -> KeyEquivalent {
        KeyEquivalent(Character(Unicode.Scalar(UInt8(0x30 + position))))
    }
}
