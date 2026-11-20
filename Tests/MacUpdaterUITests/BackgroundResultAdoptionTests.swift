import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-05 — the window used to take the menu-bar agent's result once per process, so a click
/// on "new updates" opened a list that did not have them.
@Suite("Background result adoption") @MainActor
struct BackgroundResultAdoptionTests {
    private func makeStore() -> ScanStore {
        let runner = ScanStoreRuntimeProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "{}", stderr: "") }
        return makeScanStoreRuntimeHarness(runner: runner).store
    }

    private func result(at date: Date) -> MenuBarScanResult {
        MenuBarScanResult(
            brew: BrewOutdated(formulae: [], casks: [BrewOutdatedItem(name: "adopt-cask", installedVersions: ["1"], currentVersion: "2")]),
            mas: [], npm: [], manualApps: [], failedChecks: 0, scannedAt: date, total: 1
        )
    }

    @Test func aNewerBackgroundResultReplacesTheWindowList() {
        let store = makeStore()
        let anHourAgo = Date.now.addingTimeInterval(-3600)
        store.lastCheck = anHourAgo
        store.status = .results
        let fresh = result(at: .now)
        let adopted = store.adoptBackgroundResultIfNewer(fresh)
        #expect(adopted && store.lastCheck == fresh.scannedAt)
        #expect(store.brewOutdated?.casks.map(\.name) == ["adopt-cask"])
    }

    @Test func anOlderResultChangesNothing() {
        let store = makeStore()
        let recent = Date.now
        store.lastCheck = recent
        store.status = .results
        let adopted = store.adoptBackgroundResultIfNewer(result(at: recent.addingTimeInterval(-3600)))
        #expect(!adopted)
        #expect(store.lastCheck == recent)
        #expect(store.brewOutdated == nil)
    }

    @Test func nothingIsAdoptedWhileUpdatingOrChecking() {
        let store = makeStore()
        store.lastCheck = Date.now.addingTimeInterval(-3600)
        store.status = .results
        store.updating = true
        #expect(!store.adoptBackgroundResultIfNewer(result(at: .now)))
        store.updating = false
        store.status = .checking
        #expect(!store.adoptBackgroundResultIfNewer(result(at: .now)))
        #expect(store.brewOutdated == nil)
    }
}
