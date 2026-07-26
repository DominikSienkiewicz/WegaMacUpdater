import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// REL-14: Inventory and Uninstall used to swallow every scan error, so a broken
/// brew/scanner produced a silently partial table or an empty list indistinguishable
/// from "nothing installed". These tests pin the fix: source failures are collected,
/// surfaced as `errorMessage`, and "empty" is told apart from "scan failed".
@Suite("REL-14 scan-failure surfacing")
struct ScanFailureSurfacingTests {
    private struct ScanBoom: Error {}

    private func app(name: String, brew: Bool = true) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "example.\(name.lowercased())",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: brew ? name.lowercased() : nil
        )
    }

    // MARK: - Inventory source collection

    @Test func inventoryCollectRecordsHomebrewFailureButKeepsScannedApps() async {
        let dir = URL(fileURLWithPath: "/Applications")
        let snapshot = await InventorySnapshot.collect(
            directories: [dir],
            sources: InventorySources(
                installedCasks: { throw ScanBoom() },
                availableCasks: { [] },
                scanApplications: { _, _, _ in [self.app(name: "Found")] },
                masList: { [] },
                npmGlobals: { [] }
            )
        )

        #expect(snapshot.failures.map(\.source) == [.homebrew])
        #expect(snapshot.apps.map(\.name) == ["Found"])
    }

    @Test func inventoryCollectRecordsApplicationsFailure() async {
        let snapshot = await InventorySnapshot.collect(
            directories: [URL(fileURLWithPath: "/Applications")],
            sources: InventorySources(
                installedCasks: { [] },
                availableCasks: { [] },
                scanApplications: { _, _, _ in throw ScanBoom() },
                masList: { [] },
                npmGlobals: { [] }
            )
        )

        #expect(snapshot.failures.map(\.source) == [.applications])
        #expect(snapshot.apps.isEmpty)
    }

    @Test func inventoryCollectRecordsNpmFailure() async {
        let snapshot = await InventorySnapshot.collect(
            directories: [],
            sources: InventorySources(
                installedCasks: { [] },
                availableCasks: { [] },
                scanApplications: { _, _, _ in [] },
                masList: { [] },
                npmGlobals: { throw ScanBoom() }
            )
        )

        #expect(snapshot.failures.map(\.source) == [.npm])
    }

    @Test func inventoryCollectReportsNoFailuresOnACleanEmptyScan() async {
        let snapshot = await InventorySnapshot.collect(
            directories: [URL(fileURLWithPath: "/Applications")],
            sources: InventorySources(
                installedCasks: { [] },
                availableCasks: { [] },
                scanApplications: { _, _, _ in [] },
                masList: { [] },
                npmGlobals: { [] }
            )
        )

        #expect(snapshot.apps.isEmpty)
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.failures.scanErrorMessage == nil)
    }

    // MARK: - Inventory store → errorMessage

    @MainActor
    @Test func inventoryStoreAssignsErrorMessageWhenScanReportsFailures() async {
        let snapshot = InventorySnapshot(
            apps: [],
            npmGlobals: [],
            failures: [ScanSourceFailure(source: .homebrew, message: "boom")]
        )
        let store = InventoryStore(operations: OperationCoordinator())

        await store.scan(using: StubInventoryLoader(snapshot: snapshot), onWegaState: nil)

        #expect(store.errorMessage != nil)
        #expect(store.errorMessage == snapshot.failures.scanErrorMessage)
    }

    @MainActor
    @Test func inventoryStoreLeavesErrorMessageNilOnCleanEmptyScan() async {
        let store = InventoryStore(operations: OperationCoordinator())

        await store.scan(
            using: StubInventoryLoader(snapshot: InventorySnapshot(apps: [], npmGlobals: [])),
            onWegaState: nil
        )

        #expect(store.errorMessage == nil)
        #expect(store.apps.isEmpty)
    }

    // MARK: - Uninstall source collection

    @Test func uninstallCollectRecordsHomebrewFailureButKeepsScannedApps() async {
        let scan = await UninstallScan.collect(
            directories: [URL(fileURLWithPath: "/Applications")],
            installedCasks: { throw ScanBoom() },
            scanApplications: { _, _ in [self.app(name: "Kept", brew: false)] }
        )

        #expect(scan.scanFailed)
        #expect(scan.failures.map(\.source) == [.homebrew])
        #expect(scan.apps.map(\.name) == ["Kept"])
    }

    @Test func uninstallCollectRecordsApplicationsFailure() async {
        let scan = await UninstallScan.collect(
            directories: [URL(fileURLWithPath: "/Applications")],
            installedCasks: { [] },
            scanApplications: { _, _ in throw ScanBoom() }
        )

        #expect(scan.scanFailed)
        #expect(scan.failures.map(\.source) == [.applications])
        #expect(scan.apps.isEmpty)
    }

    @Test func uninstallCollectReportsCleanScan() async {
        let scan = await UninstallScan.collect(
            directories: [URL(fileURLWithPath: "/Applications")],
            installedCasks: { [] },
            scanApplications: { _, _ in [] }
        )

        #expect(!scan.scanFailed)
        #expect(scan.apps.isEmpty)
    }

    // MARK: - List-state distinction (empty vs. scan failed)

    @Test func uninstallListStateSeparatesEmptyFromScanFailed() {
        #expect(UninstallListState.resolve(isLoading: true, appsEmpty: true, scanFailed: true) == .loading)
        #expect(UninstallListState.resolve(isLoading: false, appsEmpty: true, scanFailed: true) == .scanFailed)
        #expect(UninstallListState.resolve(isLoading: false, appsEmpty: true, scanFailed: false) == .empty)
        // Partial scan: some apps found alongside a failure — still show the apps.
        #expect(UninstallListState.resolve(isLoading: false, appsEmpty: false, scanFailed: true) == .populated)
    }

    // MARK: - Banner message

    @Test func scanErrorMessageNamesFailedSourcesAndIsNilWhenClean() {
        #expect([ScanSourceFailure]().scanErrorMessage == nil)

        let message = [ScanSourceFailure(source: .homebrew, message: "x")].scanErrorMessage
        #expect(message != nil)
        #expect(message?.contains(ScanFailureSource.homebrew.label) == true)
    }
}

private struct StubInventoryLoader: InventorySnapshotLoading {
    let snapshot: InventorySnapshot
    func load() async -> InventorySnapshot { snapshot }
}
