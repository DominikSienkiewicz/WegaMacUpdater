import Foundation
import MacUpdaterCore

@testable import WegaMacUpdater

actor InventoryReadCounter {
    private(set) var reads = 0
    func bump() { reads += 1 }
}

/// An inventory read that only counts itself, so a test can tell a reused result from a new read.
struct CountingInventoryLoader: InventorySnapshotLoading {
    private let counter = InventoryReadCounter()

    var reads: Int { get async { await counter.reads } }

    func load() async -> InventorySnapshot {
        await counter.bump()
        return InventorySnapshot(apps: [], npmGlobals: [])
    }
}

/// One entry into the Inventory screen, as `InventoryView`'s `.task` makes it.
@MainActor
func enterInventory(_ store: InventoryStore, using loader: CountingInventoryLoader, changes: InventoryChangeStamp) async {
    if store.needsRead(given: changes) {
        await store.scan(using: loader, changes: changes, onWegaState: nil)
    }
}
