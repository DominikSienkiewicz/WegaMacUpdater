import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// "Update all" must never try to replace the app that is running the update. The split that
/// decides this is not in `MacUpdaterCore` — it is `ScanStore.updateCount`
/// (`UpdatePlanner.unifiedCount(installable: allItems.count, manual: visibleManual.count)`),
/// where `allItems` is built only from `brewOutdated`/`masOutdated`/`npmOutdated` and
/// `visibleManual` from `manualOutdated`. A `ManualOutdatedApp` — Wega's own row included —
/// has no way into `allItems`; this test exercises that real split through `restoreLastScan()`
/// rather than asserting on `UnifiedUpdateCount`'s pass-through arithmetic directly, so it would
/// turn red if a refactor ever routed a manual/self-update row into the installable side.
@Suite("Self-update manual/installable split")
struct SelfUpdateManualSplitTests {
    /// A `ScanSnapshotIO` that hands back a fixed snapshot and swallows writes, so the restore
    /// path can be exercised without touching the disk.
    private struct StubIO: ScanSnapshotIO {
        let data: Data?
        func read() throws -> Data? { data }
        func write(_ data: Data) throws {}
    }

    // `ScanStore` is main-actor isolated, so its factory has to be too.
    @MainActor
    private func store(with snapshot: ScanSnapshot) throws -> ScanStore {
        let data = try JSONEncoder().encode(snapshot)
        return ScanStore(resultStore: ScanResultStore(io: StubIO(data: data)))
    }

    @MainActor
    @Test func theWegaEntryNeverJoinsTheInstallableCount() throws {
        // A random path/bundle id so a real persisted ignore/pin policy can never touch this row.
        let token = UUID().uuidString
        let wega = ManualOutdatedApp(
            name: "Wega",
            path: URL(fileURLWithPath: "/Applications/WegaMacUpdater-\(token).app"),
            installedVersion: "1.0.0",
            availableVersion: "1.2.0",
            source: .wega(releaseURL: URL(string: "https://example.com/release")!),
            origin: .manual,
            releaseNotes: "",
            bundleIdentifier: "com.wega.macupdater.\(token)"
        )
        let snapshot = ScanSnapshot(
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
            brew: nil,
            mas: [],
            npm: [],
            manual: [wega]
        )

        let scan = try store(with: snapshot)
        scan.restoreLastScan()

        #expect(scan.status == .results)
        // Wega's row must never surface as an installable `OutdatedItem` — `allItems` is built
        // only from brew/mas/npm, so a manual entry (Wega's included) structurally cannot reach it.
        #expect(scan.allItems.isEmpty)
        #expect(scan.visibleManual.map(\.name) == ["Wega"])
        // The exact count every surface reports: Wega counts as manual, never installable.
        #expect(scan.updateCount.installable == 0)
        #expect(scan.updateCount.manual == 1)
    }
}
