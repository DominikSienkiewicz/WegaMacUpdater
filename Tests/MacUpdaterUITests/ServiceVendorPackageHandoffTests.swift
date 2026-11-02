import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Package service handoffs use the verified installation through completion")
@MainActor
struct ServiceVendorPackageHandoffTests {
    @Test func packageOwnedServiceIsVisibleInTheInspectorWithoutAnIconPath() throws {
        let store = preparedStore()
        let row = try #require(store.visibleManual.first)
        #expect(row.path == installed.path)
        #expect(store.unresolvedServiceItems.isEmpty)
        #expect(store.updateCount == UnifiedUpdateCount(installable: 0, manual: 1))
        store.inspectedKey = "c:logi-options+"
        #expect(store.inspectedUpdate == .manual(row))
    }

    @Test func verifiedProductTargetClosesThePackageOwnedServiceUpdate() async throws {
        let store = preparedStore()
        let row = try #require(store.visibleManual.first)
        await store.checkVendorUpdate(row)
        #expect(store.allItems.isEmpty)
        #expect(store.visibleManual.isEmpty)
        #expect(store.updateCount == UnifiedUpdateCount(installable: 0, manual: 0))
    }

    private func preparedStore() -> ScanStore {
        let runner = ScanStoreRuntimeProcessRunner { _ in
            Issue.record("A package vendor handoff must not run Homebrew or alter a service")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        var dependencies = harness.store.dependencies
        let installed = installed
        dependencies.checkVendorUpdate = { _ in .init(app: installed, outcome: .confirmed) }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.status = .results
        store.brewOutdated = .init(formulae: [], casks: [.init(name: "logi-options+", installedVersions: ["1"], currentVersion: "2")])
        var check = InstallationCheck(app: installed, sources: [], checkedAt: Date())
        check.caskToken = "logi-options+"
        store.installationChecks = [check]
        return store
    }

    private var installed: ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/logioptionsplus.app"), name: "Logi Options+",
                        bundleIdentifier: "com.logi.optionsplus", version: "2", installDate: nil, updateDate: nil,
                        isManagedByBrew: true, caskToken: "logi-options+")
    }
}
