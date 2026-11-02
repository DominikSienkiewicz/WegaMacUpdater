import Foundation
import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class DockerDesktopPolicyRoutingTests: XCTestCase {
    func testManagedAndUnresolvedDockerRemainVisibleWithoutBulkSelection() throws {
        let store = makeScanStoreRuntimeHarness(runner: noProcesses()).store
        store.status = .results
        store.brewOutdated = .init(formulae: [], casks: [
            .init(name: "docker-desktop", installedVersions: ["4.50"], currentVersion: "4.51")
        ])
        store.selected = ["c:docker-desktop"]
        XCTAssertEqual(store.allItems.count, 1)
        XCTAssertTrue(store.visibleItems(for: .all).isEmpty)
        XCTAssertTrue(store.updateTargets(for: .all).isEmpty)
        XCTAssertEqual(store.updateCount, UnifiedUpdateCount(installable: 0, manual: 1))
        store.toggleAll(filter: .all)
        XCTAssertTrue(store.selected.isEmpty)
        let path = URL(fileURLWithPath: "/Applications/Docker.app")
        store.caskIconPaths = ["docker-desktop": path]
        let app = ApplicationInfo(path: path, name: "Docker", bundleIdentifier: "com.docker.docker",
                                 version: "4.50", installDate: nil, updateDate: nil, isManagedByBrew: true)
        store.installationChecks = [InstallationCheck(app: app, sources: [], checkedAt: Date())]
        let row = try XCTUnwrap(store.visibleManual.first)
        XCTAssertEqual(row.path, path)
        XCTAssertEqual(store.visibleManual.count, 1)
        XCTAssertEqual(store.updateCount, UnifiedUpdateCount(installable: 0, manual: 1))
        store.inspectedKey = "c:docker-desktop"
        XCTAssertEqual(store.inspectedUpdate, .manual(row))
    }

    func testLocalConfirmationClosesTheManagedDockerRow() async throws {
        let harness = makeScanStoreRuntimeHarness(runner: noProcesses())
        let path = URL(fileURLWithPath: "/Applications/Docker.app")
        let app = ApplicationInfo(path: path, name: "Docker", bundleIdentifier: "com.docker.docker",
                                 version: "4.51", installDate: nil, updateDate: nil, isManagedByBrew: true)
        var recorded: [UpdateJournalEntry] = []
        var dependencies = harness.store.dependencies
        dependencies.checkVendorUpdate = { _ in .init(app: app, outcome: .confirmed) }
        dependencies.recordUpdateRun = { recorded.append($0) }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.status = .results
        store.brewOutdated = .init(formulae: [], casks: [
            .init(name: "docker-desktop", installedVersions: ["4.50"], currentVersion: "4.51")
        ])
        store.caskIconPaths = ["docker-desktop": path]
        store.installationChecks = [InstallationCheck(app: app, sources: [], checkedAt: Date())]
        let row = try XCTUnwrap(store.visibleManual.first)
        store.vendorOpened(row, succeeded: true)
        await store.checkVendorUpdate(row)
        XCTAssertTrue(store.visibleManual.isEmpty)
        XCTAssertTrue(store.allItems.isEmpty)
        XCTAssertEqual(recorded.first?.trigger, .external)
        XCTAssertEqual(recorded.first?.upgradedCount, 1)
    }

    private func noProcesses() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner { _ in
            XCTFail("Docker handoff policy must not execute a process")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
    }

    func testDockerIsAbsentFromBatchPreviewAndOpeningOnlyRecordsPendingHandoff() {
        let runner = ScanStoreRuntimeProcessRunner { _ in
            XCTFail("Opening a vendor handoff or planning must not execute a package manager")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        var recorded: [UpdateJournalEntry] = []
        var dependencies = harness.store.dependencies
        dependencies.recordUpdateRun = { recorded.append($0) }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.status = .results
        let path = URL(fileURLWithPath: "/Applications/Docker.app")
        let item = ManualOutdatedApp(name: "Docker", path: path, installedVersion: "4.50", availableVersion: "4.51",
            source: .cask(token: "docker-desktop"), origin: .brew, bundleIdentifier: "com.docker.docker",
            completionRequirement: .init(version: "4.51"))
        XCTAssertTrue(store.plannedCommands(targetKeys: ["c:docker-desktop"]).isEmpty)
        XCTAssertTrue(store.plannedCaskTokens(targetKeys: ["c:docker"]).isEmpty)
        store.vendorOpened(item, succeeded: true)
        XCTAssertEqual(store.vendorHandoffs, [item])
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertTrue(store.visibleManual.contains(item))
    }
}
