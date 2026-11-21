import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-14 — a launch scan reuses a Homebrew catalog younger than 30 minutes and the band says
/// how old it is; the manual "Check now" always refreshes.
@Suite("Catalog threshold at launch") @MainActor
struct CatalogThresholdTests {
    @MainActor private final class SavedStamps {
        var dates: [Date] = []
    }

    @Test func aLaunchWithinHalfAnHourSkipsBrewUpdateAndNamesTheCatalogsAge() async throws {
        let f = try fixture(stampMinutesAgo: 12)
        let store = f.store
        store.startLaunchRefresh()
        await store.scanTask?.value
        #expect(!f.runner.requests.contains { $0.arguments.first == "update" })
        #expect(store.catalogAgeMinutes == 12)
        #expect(f.saved.dates.isEmpty)
    }

    @Test func aStaleMissingOrFutureStampRefreshesAtLaunch() async throws {
        for minutes in [31, nil, -5] as [Int?] {
            let f = try fixture(stampMinutesAgo: minutes)
            let store = f.store
            store.startLaunchRefresh()
            await store.scanTask?.value
            #expect(f.runner.requests.contains { $0.arguments.first == "update" }, "\(String(describing: minutes))")
            #expect(store.catalogAgeMinutes == nil && f.saved.dates.count == 1)
        }
    }

    @Test func checkNowAlwaysRefreshesTheCatalog() async throws {
        let f = try fixture(stampMinutesAgo: 2)
        let store = f.store
        store.startCheck()
        await store.scanTask?.value
        #expect(f.runner.requests.contains { $0.arguments.first == "update" })
        #expect(store.catalogAgeMinutes == nil)
    }

    @Test func aFailedRefreshKeepsTheOldStamp() async throws {
        let f = try fixture(stampMinutesAgo: 45, updateExitCode: 1)
        let store = f.store
        store.startLaunchRefresh()
        await store.scanTask?.value
        #expect(f.saved.dates.isEmpty, "the next launch must try again")
    }

    @Test func aResultFromTheBackgroundMakesNoCatalogClaim() async throws {
        let f = try fixture(stampMinutesAgo: 12)
        let store = f.store
        store.startLaunchRefresh()
        await store.scanTask?.value
        #expect(store.catalogAgeMinutes == 12)
        store.adoptBackgroundResultIfNewer(MenuBarScanResult(brew: nil, mas: [], npm: [], manualApps: [], failedChecks: 0,
                                                             scannedAt: .now.addingTimeInterval(60), total: 0))
        #expect(store.catalogAgeMinutes == nil)
    }

    private struct Fixture {
        let store: ScanStore
        let runner: ScanStoreRuntimeProcessRunner
        let saved: SavedStamps
    }

    private func fixture(stampMinutesAgo minutes: Int?, updateExitCode: Int32 = 0) throws -> Fixture {
        let runner = ScanStoreRuntimeProcessRunner { request in
            if request.arguments.first == "update" { return ProcessResult(exitCode: updateExitCode, stdout: "", stderr: "") }
            let output = request.arguments.contains("--json=v2") ? "{\"formulae\":[],\"casks\":[]}"
                : request.arguments.contains("--json") ? "{}" : ""
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        let now = Date()
        let saved = SavedStamps()
        let stamp = minutes.map { now.addingTimeInterval(-Double($0) * 60) }
        var deps = harness.store.dependencies
        deps.catalogStamp = BrewCatalogStamp(load: { stamp }, save: { saved.dates.append($0) })
        deps.now = { now }
        deps.manualScanWithProgress = { _, _, _ in ManualScanReport(apps: [], failedChecks: 0) }
        let store = ScanStore(
            resultStore: ScanResultStore(io: harness.snapshots),
            runningApplicationInspector: ScanStoreRuntimeApplicationInspector(applications: []),
            dependencies: deps,
            announcer: RecordingAnnouncer()
        )
        store.attach(model: try #require(harness.store.model))
        return Fixture(store: store, runner: runner, saved: saved)
    }
}
