import Combine
import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-13 — what the band reads while a scan runs: when it started, which step it is on and how
/// many vendor apps have answered. All of it belongs to one scan and ends with it, so a
/// cancelled scan or a late report from the previous one never leaves a number behind.
@Suite("Scan progress reporting") @MainActor
struct ScanProgressReportingTests {
    @Test func vendorProgressArrivesInOrderAndClearsWithTheScan() async throws {
        let (store, _) = try storeReporting([.init(checkedApps: 0, totalApps: 2), .init(checkedApps: 1, totalApps: 2),
                                             .init(checkedApps: 2, totalApps: 2)])
        var seen: [ManualScanProgress?] = []
        let sub = store.$manualScanProgress.sink { seen.append($0) }
        defer { sub.cancel() }
        await store.runCheck(quiet: true)
        #expect(seen.compactMap { $0 } == [.init(checkedApps: 0, totalApps: 2), .init(checkedApps: 1, totalApps: 2),
                                            .init(checkedApps: 2, totalApps: 2)])
        #expect(store.manualScanProgress == nil && store.scanStartedAt == nil && !store.isRefreshing)
    }

    @Test func theScanClockRunsOnlyWhileTheScanDoes() async throws {
        let (store, _) = try storeReporting([])
        var starts: [Date?] = []
        let sub = store.$scanStartedAt.sink { starts.append($0) }
        defer { sub.cancel() }
        await store.runCheck(quiet: true)
        #expect(starts.contains { $0 != nil }, "the eyebrow has a start to count from")
        #expect(starts.last == .some(nil))
    }

    @Test func onlyTheCurrentScansVendorPhaseMovesForward() {
        let one = ManualScanProgress(checkedApps: 1, totalApps: 2), two = ManualScanProgress(checkedApps: 2, totalApps: 2)
        #expect(ScanStore.acceptsManualProgress(two, current: one, generation: 3, currentGeneration: 3, phase: .running(.manual)))
        #expect(!ScanStore.acceptsManualProgress(two, current: one, generation: 2, currentGeneration: 3, phase: .running(.manual)),
                "a late report from the previous scan")
        #expect(!ScanStore.acceptsManualProgress(one, current: two, generation: 3, currentGeneration: 3, phase: .running(.manual)),
                "never backwards")
        #expect(!ScanStore.acceptsManualProgress(two, current: nil, generation: 3, currentGeneration: 3, phase: .finished))
    }

    @Test func aCancelledScanLeavesNoScanStateBehind() async throws {
        let (store, _) = try storeReporting([.init(checkedApps: 0, totalApps: 2)])
        store.startCheck(quiet: true)
        store.cancelScan()
        await store.scanTask?.value
        #expect(store.scanStartedAt == nil && store.manualScanProgress == nil)
        #expect(!store.isRefreshingCatalog && !store.isRefreshing, "the band goes back to the results state")
    }

    @Test func theCatalogRefreshIsItsOwnStep() async throws {
        let (store, _) = try storeReporting([])
        var flags: [Bool] = []
        let sub = store.$isRefreshingCatalog.sink { flags.append($0) }
        defer { sub.cancel() }
        await store.runCheck(quiet: true)
        #expect(flags.contains(true) && flags.last == false)
        flags = []
        await store.runCheck(lightweight: true, quiet: true)
        #expect(!flags.contains(true), "a post-run rescan skips brew update")
    }

    /// M10 — a copy of `.live` carries the live progress scan. A test that stubs
    /// `detailedManualScan` on it must get its stub, not the real scanner; a recording progress
    /// scan stands in for the live one here.
    @Test func aStubbedDetailedScanWinsOverTheProgressScan() async throws {
        let app = ManualOutdatedApp(
            name: "Stubbed", path: URL(fileURLWithPath: "/Applications/Stubbed-\(UUID().uuidString).app"),
            installedVersion: "1", availableVersion: "2", source: .sparkle,
            bundleIdentifier: "example.stubbed.\(UUID().uuidString)"
        )
        let progressScan = ProgressScanRecorder()
        let (store, _) = try storeReporting([], recorder: progressScan) { _, _ in
            ManualScanReport(apps: [app], failedChecks: 0)
        }

        await store.runCheck(quiet: true)

        #expect(store.manualOutdated.map(\.name) == ["Stubbed"])
        #expect(!progressScan.ran, "the progress scan a copy of .live carries stays out of the way")
        #expect(ScanStoreDependencies.live.detailedManualScan == nil && ScanStoreDependencies.live.manualScanWithProgress != nil,
                "the app itself runs the progress scan")
    }

    @MainActor private final class ProgressScanRecorder {
        var ran = false
    }

    /// A store whose manual scan replays `values` through the progress sink, built like
    /// `ScanStatusPipelineTests`' one: the harness's runner, lock and snapshot store, with the
    /// vendor scan swapped for the one that reports. `detailed`, when given, is a stubbed
    /// detailed scan next to it.
    private func storeReporting(
        _ values: [ManualScanProgress],
        recorder: ProgressScanRecorder? = nil,
        detailed: ((BrewService, Set<String>) async -> ManualScanReport)? = nil
    ) throws -> (ScanStore, ScanStoreRuntimeHarness) {
        let runner = ScanStoreRuntimeProcessRunner { request in
            let output: String
            if request.arguments.contains("--json=v2") { output = "{\"formulae\":[],\"casks\":[]}" }
            else if request.arguments.contains("--json") { output = "{}" }
            else { output = "" }
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        var deps = harness.store.dependencies
        deps.manualScanWithProgress = { _, _, report in
            recorder?.ran = true
            for p in values { await report(p) }
            return ManualScanReport(apps: [], failedChecks: 0)
        }
        deps.detailedManualScan = detailed
        let store = ScanStore(
            resultStore: ScanResultStore(io: harness.snapshots),
            runningApplicationInspector: ScanStoreRuntimeApplicationInspector(applications: []),
            dependencies: deps,
            announcer: RecordingAnnouncer()
        )
        store.attach(model: try #require(harness.store.model))
        return (store, harness)
    }
}
