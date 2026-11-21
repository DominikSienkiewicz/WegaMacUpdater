import AppKit
import MacUpdaterCore
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// UXP-30 — the inventory toolbar row grew by a read time, „Odśwież spis” and „Sprawdź
/// aktualizacje”. The window's minimum is 980 pt, the sidebar takes 240, so the detail column
/// offers 740 pt.
@Suite("Inventory toolbar width") @MainActor
struct InventoryToolbarWidthTests {
    private static let detailWidth: CGFloat = WegaLayout.windowMinWidth - 240

    private func idealWidth(language: AppLanguage, stale: Bool) async -> CGFloat {
        let inventory = InventoryStore(operations: OperationCoordinator())
        await inventory.scan(using: WidthLoader(), onWegaState: nil)
        if stale { inventory.markStale() }
        return withLanguage(language) {
            let view = InventoryView()
                .environmentObject(AppViewModel())
                .environmentObject(ScanStore())
                .environmentObject(inventory)
                .environmentObject(WegaCommandCenter())
            return NSHostingView(rootView: view).fittingSize.width
        }
    }

    @Test func theToolbarRowFitsTheNarrowestDetailColumn() async {
        for language in [AppLanguage.pl, .en] {
            for stale in [false, true] {
                let width = await idealWidth(language: language, stale: stale)
                #expect(width <= Self.detailWidth, "\(language) stale=\(stale): \(width) pt")
            }
        }
    }
}

private struct WidthLoader: InventorySnapshotLoading {
    func load() async -> InventorySnapshot {
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: "uxp30.slack",
            version: "1", installDate: nil, updateDate: nil, isManagedByBrew: false
        )
        return InventorySnapshot(apps: [app], npmGlobals: [])
    }
}
