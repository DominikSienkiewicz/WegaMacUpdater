import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// Homebrew's `outdated --greedy` answer lists every self-updating cask whose Caskroom record lags
/// the app on disk (14 on the owner's Mac on 2026-11-22: chatgpt, google-chrome, zed…). The scan
/// drops them only after the vendor phase, which says which copies are already current. The raw
/// answer used to reach the screen before that: for the scan's middle twenty seconds the list and
/// the band showed fourteen updates that were not there, then lost them. On an up-to-date Mac the
/// band appeared only while a scan ran.
@Suite("The raw Homebrew answer stays off screen") @MainActor
struct ScanRawBrewAnswerTests {
    @Test func theListKeepsThePreviousAnswerUntilTheScanHasFilteredTheNewOne() async throws {
        let previous = "previous-\(UUID().uuidString)", fresh = "fresh-\(UUID().uuidString)"
        let probe = MidScanProbe()
        let store = try storeAnswering(cask: fresh) { handed in
            probe.handed = handed
            probe.listMidScan = probe.store?.allItems.map(\.name)
        }
        probe.store = store
        store.brewOutdated = BrewOutdated(formulae: [], casks: [
            BrewOutdatedItem(name: previous, installedVersions: ["1.0"], currentVersion: "2.0")
        ])
        store.lastCheck = Date(timeIntervalSince1970: 1_000)
        store.status = .results

        await store.runCheck(quiet: true)

        #expect(probe.listMidScan == [previous], "the scan in place keeps the last filtered answer on screen")
        #expect(probe.handed == [fresh], "the vendor phase still hears which casks Homebrew offers")
        #expect(store.allItems.map(\.name) == [fresh])
    }

    @MainActor private final class MidScanProbe {
        weak var store: ScanStore?
        var listMidScan: [String]?
        var handed: Set<String> = []
    }

    /// A store whose Homebrew offers one cask, `cask`, and whose vendor phase runs `midScan`.
    private func storeAnswering(cask: String, midScan: @escaping (Set<String>) -> Void) throws -> ScanStore {
        let runner = ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                let json = #"{"formulae":[],"casks":[{"name":"\#(cask)","installed_versions":["1.0"],"current_version":"2.0"}]}"#
                return ProcessResult(exitCode: 0, stdout: json, stderr: "")
            case ["outdated", "-g", "--json"]:
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            default:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        var dependencies = harness.store.dependencies
        dependencies.detailedManualScan = { _, casks in
            midScan(casks)
            return ManualScanReport(apps: [], failedChecks: 0)
        }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.attach(model: try #require(harness.store.model))
        return store
    }
}
