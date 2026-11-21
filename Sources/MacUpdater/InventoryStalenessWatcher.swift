import SwiftUI

/// Marks the inventory stale whenever something that changes the installed apps finishes:
/// an update run, a Cleanup removal or a migration. The uninstall screen reports its own
/// completion. A zero-size, always-present view so the modifiers fire, and so the stores it
/// reads do not redraw `ContentView` on every published change.
struct InventoryStalenessWatcher: View {
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var cleanup: CleanupStore
    @EnvironmentObject private var migration: MigrationStore
    @EnvironmentObject private var inventory: InventoryStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onChange(of: scan.updating) { was, now in
                if was, !now { inventory.markStale() }
            }
            .onChange(of: cleanup.removalCount) { inventory.markStale() }
            .onChange(of: migration.migrating) { was, now in
                if was != nil, now == nil { inventory.markStale() }
            }
            .onChange(of: migration.duplicateBusyKey) { was, now in
                if was != nil, now == nil { inventory.markStale() }
            }
    }
}
