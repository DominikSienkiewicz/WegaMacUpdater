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

    @Test func aHomebrewRecordOfAVendorAppThatIsNotInstalledIsNotListed() {
        let store = preparedStore()
        store.installationChecks = []
        #expect(store.serviceManagedUpdates.isEmpty)
        #expect(store.unresolvedServiceItems.isEmpty)
        #expect(store.updateCount == UnifiedUpdateCount(installable: 0, manual: 0))
    }

    @Test func aTokenAPendingHandoffAlreadyCoversIsNotListedASecondTime() throws {
        let store = preparedStore()
        let handoff = try #require(store.visibleManual.first)
        var elsewhere = InstallationCheck(app: installed, sources: [], checkedAt: Date())
        elsewhere.caskToken = nil
        store.installationChecks = [elsewhere]
        store.vendorHandoffs = [handoff]
        #expect(store.serviceManagedUpdates.isEmpty, "the cask no longer resolves to an installation")
        #expect(store.unresolvedServiceItems.isEmpty)
    }

    @Test func aScanDropsAVendorCaskWhoseAppIsNotInstalledEntirely() async {
        let store = scannedStore(installations: [], failedChecks: 0)
        await store.runCheck()
        #expect(store.lastScanComplete)
        #expect(store.allItems.isEmpty)
        #expect(store.visibleManual.isEmpty)
        #expect(store.unresolvedServiceItems.isEmpty)
        #expect(store.updateCount == UnifiedUpdateCount(installable: 0, manual: 0))
    }

    @Test func aScanDropsAVendorCaskWhoseInstalledAppAlreadyHasTheTarget() async {
        let store = scannedStore(
            installations: [InstallationCheck(app: application(version: "2"), sources: [], checkedAt: Date())],
            failedChecks: 0
        )
        await store.runCheck()
        #expect(store.allItems.isEmpty)
        #expect(store.unresolvedServiceItems.isEmpty)
        #expect(store.updateCount == UnifiedUpdateCount(installable: 0, manual: 0))
    }

    @Test func anIncompleteScanKeepsTheVendorCardItCannotJudge() async {
        let store = scannedStore(installations: [], failedChecks: 1)
        await store.runCheck()
        #expect(!store.lastScanComplete)
        #expect(store.allItems.map(\.name) == ["logi-options+"])
        #expect(store.unresolvedServiceItems.map(\.name) == ["logi-options+"])
        #expect(store.updateCount == UnifiedUpdateCount(installable: 0, manual: 1))
    }

    @Test func anInstalledAppBelowTheTargetStaysAsARow() async {
        let store = scannedStore(
            installations: [InstallationCheck(app: application(version: "1"), sources: [], checkedAt: Date())],
            failedChecks: 0
        )
        await store.runCheck()
        #expect(store.allItems.map(\.name) == ["logi-options+"])
        #expect(store.updateCount.manual == 1)
    }

    private func scannedStore(installations: [InstallationCheck], failedChecks: Int) -> ScanStore {
        let runner = ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["update"], ["list", "--cask", "-1"]:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                let json = #"{"formulae":[],"casks":[{"name":"logi-options+","installed_versions":["1"],"current_version":"2"}]}"#
                return ProcessResult(exitCode: 0, stdout: json, stderr: "")
            case ["outdated"]:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            case ["outdated", "-g", "--json"]:
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            default:
                return ProcessResult(exitCode: 1, stdout: "", stderr: "")
            }
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        var dependencies = harness.store.dependencies
        let report = ManualScanReport(apps: [], failedChecks: failedChecks, installations: installations)
        dependencies.detailedManualScan = { _, _ in report }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        if let model = harness.store.model { store.attach(model: model) }
        return store
    }

    /// The scan decides whether a vanished hand-off may be dropped from `lastScanComplete`, so
    /// the live scan must publish its own completeness before closing hand-offs, not the
    /// previous scan's.
    @Test func aLiveScanPublishesItsCompletenessBeforeItClosesHandoffs() throws {
        let scanning = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MacUpdater/ScanStore+Scanning.swift"),
            encoding: .utf8
        )
        let publish = try #require(scanning.range(of: "applyScanSourceReports(reports)")?.lowerBound)
        let close = try #require(scanning.range(of: "closeVendorHandoffsConfirmedByScan()")?.lowerBound)
        #expect(publish < close)
    }

    private func preparedStore() -> ScanStore {
        let runner = ScanStoreRuntimeProcessRunner { _ in
            Issue.record("A package vendor handoff must not run Homebrew or alter a service")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        var dependencies = harness.store.dependencies
        let installed = installed
        let updated = application(version: "2")
        dependencies.checkVendorUpdate = { _ in .init(app: updated, outcome: .confirmed) }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.status = .results
        store.brewOutdated = .init(formulae: [], casks: [.init(name: "logi-options+", installedVersions: ["1"], currentVersion: "2")])
        var check = InstallationCheck(app: installed, sources: [], checkedAt: Date())
        check.caskToken = "logi-options+"
        store.installationChecks = [check]
        return store
    }

    /// On disk below the cask's target "2", so Homebrew's record is a real pending update.
    private var installed: ApplicationInfo { application(version: "1") }

    private func application(version: String) -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/logioptionsplus.app"), name: "Logi Options+",
                        bundleIdentifier: "com.logi.optionsplus", version: version, installDate: nil, updateDate: nil,
                        isManagedByBrew: true, caskToken: "logi-options+")
    }
}
