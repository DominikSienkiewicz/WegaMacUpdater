import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Foreground update lists reconcile vendor and Homebrew offers")
@MainActor
struct IndependentVendorPresentationTests {
    @Test func aNewerVendorOfferCannotBeReplacedByALaggingBrewBatchAction() {
        let store = fixture(brewVersion: "2.0.0")
        #expect(store.allItems.isEmpty)
        #expect(store.visibleManual.count == 1)
        #expect(store.visibleManual.first?.availableVersion == "3.0.0")
        #expect(store.visibleManual.first?.source == .chrome)
        #expect(store.updateTargets(for: .all).isEmpty)
        #expect(store.updateCount.total == 1)
    }

    @Test func aNewerBrewOfferKeepsItsExistingInstallerAndDoesNotDoubleCount() {
        let store = fixture(brewVersion: "4.0.0")
        #expect(store.allItems.count == 1)
        #expect(store.allItems.first?.to == "4.0.0")
        #expect(store.visibleManual.isEmpty)
        #expect(store.updateTargets(for: .all).map(\.key) == ["c:independent-vendor-fixture"])
        #expect(store.updateCount.total == 1)
    }

    private func fixture(brewVersion: String) -> ScanStore {
        let runner = ScanStoreRuntimeProcessRunner { _ in
            Issue.record("Presenting fixture scan results must not launch a process")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let store = makeScanStoreRuntimeHarness(runner: runner).store
        store.status = .results
        store.brewOutdated = .init(formulae: [], casks: [
            .init(name: "independent-vendor-fixture", installedVersions: ["1.0.0"], currentVersion: brewVersion)
        ])
        store.manualOutdated = [ManualOutdatedApp(
            name: "Vendor fixture", path: URL(fileURLWithPath: "/fixture/Independent Vendor.app"),
            installedVersion: "1.0.0", availableVersion: "3.0.0", source: .chrome, origin: .brew,
            bundleIdentifier: "com.example.independent-vendor", caskPolicyToken: "independent-vendor-fixture"
        )]
        store.selected = ["c:independent-vendor-fixture"]
        return store
    }
}
