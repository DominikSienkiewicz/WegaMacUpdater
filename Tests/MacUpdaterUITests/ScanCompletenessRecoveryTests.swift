import Foundation
import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

@MainActor
final class ScanCompletenessRecoveryTests: XCTestCase {
    func testPersistingAnUnconfirmedSnapshotDoesNotRestoreCompletenessFromItsSources() throws {
        let harness = makeScanStoreRuntimeHarness(runner: absentToolsRunner())
        let snapshot = ScanSnapshot(
            scannedAt: Date(timeIntervalSince1970: 4_000_000_000), brew: nil, mas: [], npm: [], manual: [],
            sources: ScanSourceReports(manual: .init(outcome: .succeeded)), isComplete: false
        )
        try ScanResultStore(io: harness.snapshots).save(snapshot)

        harness.store.restoreLastScan()
        XCTAssertFalse(harness.store.lastScanComplete)
        harness.store.persistLastScan()

        let saved = try JSONDecoder().decode(ScanSnapshot.self, from: XCTUnwrap(harness.snapshots.data))
        XCTAssertFalse(saved.isComplete)
        XCTAssertEqual(saved.sources, snapshot.sources)
    }

    func testManualFailureNamesReachTheBannerAndSavedReport() async throws {
        let sources = ["GitHub · Wega", "Sparkle · Example"]
        let harness = try detailedHarness(report: .init(apps: [], failedChecks: 2, uncheckedSources: sources))

        await harness.store.runCheck()

        let detail = trf("Nie udało się sprawdzić: %@", sources.joined(separator: ", "))
        XCTAssertEqual(harness.store.banner?.message, detail)
        XCTAssertEqual(harness.store.banner?.action, .openLogs)
        XCTAssertEqual(harness.store.sourceReports.manual?.error, detail)
        XCTAssertFalse(harness.store.lastScanComplete)
        let saved = try JSONDecoder().decode(ScanSnapshot.self, from: XCTUnwrap(harness.snapshots.data))
        XCTAssertEqual(saved.sources.manual?.error, detail)
        XCTAssertFalse(saved.isComplete)
    }

    func testCountOnlyManualFailureRetainsTheGenericExplanation() async {
        let harness = makeScanStoreRuntimeHarness(runner: absentToolsRunner(), manualScan: { _, _ in ([], 1) })

        await harness.store.runCheck()

        XCTAssertEqual(harness.store.banner?.message,
                       tr("Część źródeł nie odpowiedziała — sprawdź połączenie z internetem i spróbuj ponownie."))
        XCTAssertFalse(harness.store.lastScanComplete)
    }

    private func detailedHarness(report: ManualScanReport) throws -> ScanStoreRuntimeHarness {
        let base = makeScanStoreRuntimeHarness(runner: absentToolsRunner())
        var dependencies = base.store.dependencies
        dependencies.detailedManualScan = { _, _ in report }
        let store = ScanStore(resultStore: ScanResultStore(io: base.snapshots),
                              runningApplicationInspector: base.store.runningApplicationInspector,
                              dependencies: dependencies)
        store.attach(model: try XCTUnwrap(base.store.model))
        return ScanStoreRuntimeHarness(store: store, snapshots: base.snapshots, reports: base.reports)
    }

    private func absentToolsRunner() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["update"], ["list", "--cask", "-1"],
                 ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                throw BrewServiceError.brewNotFound
            case ["outdated"]:
                throw MasServiceError.masNotFound
            case ["outdated", "-g", "--json"]:
                throw NpmServiceError.npmNotFound
            default:
                throw UnexpectedRequest(arguments: request.arguments)
            }
        }
    }

    private struct UnexpectedRequest: Error {
        let arguments: [String]
    }
}
