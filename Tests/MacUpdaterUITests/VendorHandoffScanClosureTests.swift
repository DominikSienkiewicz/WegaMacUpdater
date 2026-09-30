import Foundation
import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class VendorHandoffScanClosureTests: XCTestCase {
    func testFullScanThatFindsTheHandedOffAppCurrentClosesTheHandoffLikeAManualCheck() async throws {
        var entries: [UpdateJournalEntry] = []
        let (store, snapshots) = try storeScanning(sourceOutcome: .current) { entries.append($0) }

        await store.runCheck()

        XCTAssertTrue(store.vendorHandoffs.isEmpty)
        XCTAssertTrue(store.visibleManual.isEmpty, "The stale 1.14.2 → 1.14.3 row must not survive a scan that found 1.14.3 current")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.trigger, .external)
        XCTAssertEqual(entries.first?.upgradedCount, 1)
        let snapshot = try XCTUnwrap(ScanResultStore(io: snapshots).load())
        XCTAssertTrue(snapshot.vendorHandoffs.isEmpty)
    }

    func testFullScanWithAFailedVendorSourceKeepsTheHandoffUnconfirmed() async throws {
        let (store, _) = try storeScanning(sourceOutcome: .failed) { _ in
            XCTFail("A failed source is not evidence that the vendor update finished")
        }

        await store.runCheck()

        XCTAssertEqual(store.vendorHandoffs, [handoff()])
        XCTAssertEqual(store.visibleManual, [handoff()])
    }

    func testRestoredSnapshotWhoseScanFoundTheAppCurrentClosesTheHandoff() throws {
        let harness = makeScanStoreRuntimeHarness(runner: runner())
        var entries: [UpdateJournalEntry] = []
        var dependencies = harness.store.dependencies
        dependencies.recordUpdateRun = { entries.append($0) }
        try ScanResultStore(io: harness.snapshots).save(ScanSnapshot(
            scannedAt: Date(timeIntervalSince1970: 3_000), brew: nil, mas: [], npm: [], manual: [],
            installationChecks: [scanCheck(.current)], vendorHandoffs: [handoff()]
        ))
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)

        store.restoreLastScan()

        XCTAssertTrue(store.vendorHandoffs.isEmpty)
        XCTAssertTrue(store.visibleManual.isEmpty)
        XCTAssertEqual(entries.map(\.trigger), [.external])
    }

    private func storeScanning(
        sourceOutcome: InstallationSourceCheck.Outcome,
        record: @escaping (UpdateJournalEntry) -> Void
    ) throws -> (ScanStore, ScanStoreRuntimeSnapshotIO) {
        let harness = makeScanStoreRuntimeHarness(runner: runner())
        var dependencies = harness.store.dependencies
        let report = ManualScanReport(apps: [], failedChecks: sourceOutcome == .failed ? 1 : 0,
                                      installations: [scanCheck(sourceOutcome)])
        dependencies.detailedManualScan = { _, _ in report }
        dependencies.recordUpdateRun = record
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.attach(model: try XCTUnwrap(harness.store.model))
        store.lastCheck = Date(timeIntervalSince1970: 1_000)
        store.status = .results
        store.manualOutdated = [handoff()]
        store.vendorHandoffs = [handoff()]
        return (store, harness.snapshots)
    }

    private func runner() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner { request in
            let output: String
            if request.arguments.contains("--json=v2") { output = "{\"formulae\":[],\"casks\":[]}" }
            else if request.arguments.contains("--json") { output = "{}" }
            else { output = "" }
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        }
    }

    private func scanCheck(_ outcome: InstallationSourceCheck.Outcome) -> InstallationCheck {
        let updated = ApplicationInfo(path: handoff().path, name: "Obsidian", bundleIdentifier: "md.obsidian",
                                      version: "1.12.7", buildVersion: "1.12.7",
                                      installDate: nil, updateDate: nil, isManagedByBrew: false)
        return InstallationCheck(app: updated, sources: [.init(source: "Obsidian", outcome: outcome)], checkedAt: Date())
    }

    private func handoff() -> ManualOutdatedApp {
        ManualOutdatedApp(name: "Obsidian", path: URL(fileURLWithPath: "/Applications/Obsidian.app"),
                          installedVersion: "1.14.2", availableVersion: "1.14.3", source: .obsidian,
                          bundleIdentifier: "md.obsidian", completionRequirement: .init(version: "1.14.3", field: .sharedPackage, scheme: .semver))
    }
}
