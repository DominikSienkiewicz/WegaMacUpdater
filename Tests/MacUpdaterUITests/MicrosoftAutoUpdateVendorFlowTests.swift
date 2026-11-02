import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Microsoft AutoUpdate UI handoff state")
@MainActor
struct MicrosoftAutoUpdateVendorFlowTests {
    @Test func successfulHandoffRemainsPendingWithoutAnInstallationSuccess() {
        let runner = ScanStoreRuntimeProcessRunner { _ in
            Issue.record("A vendor UI handoff must not run an installer")
            return .init(exitCode: 1, stdout: "", stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner, manualScan: { _, _ in ([], 0) })
        var dependencies = harness.store.dependencies
        dependencies.recordUpdateRun = { _ in Issue.record("Opening Microsoft AutoUpdate is not an installation") }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        let item = ManualOutdatedApp(name: "Word", path: URL(fileURLWithPath: "/wega-test-fixtures/Word.app"),
            installedVersion: "16.28", availableVersion: "16.29.1", source: .microsoftAutoUpdate(applicationID: "MSWD2019"),
            bundleIdentifier: "com.microsoft.Word", completionRequirement: .init(version: "16.29.1"))
        store.status = .results
        store.manualOutdated = [item]
        store.vendorOpened(item, succeeded: true)
        #expect(store.vendorHandoffs == [item])
        #expect(store.visibleManual == [item])
        #expect(store.installationChecks.isEmpty)
    }
}
