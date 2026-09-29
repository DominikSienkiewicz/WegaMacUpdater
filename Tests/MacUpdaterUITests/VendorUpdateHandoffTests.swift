import Foundation
import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class VendorUpdateHandoffTests: XCTestCase {
    func testOpeningOnlyRecordsPendingStateAndPersistsItAcrossRelaunch() throws {
        let harness = harness()
        let item = update()
        harness.store.vendorOpened(item, succeeded: true)

        XCTAssertEqual(harness.store.vendorHandoffs, [item])
        XCTAssertEqual(harness.store.visibleManual, [item])
        XCTAssertEqual(harness.store.lastCheck, timestamp)
        let restored = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: harness.store.dependencies)
        restored.restoreLastScan()
        XCTAssertEqual(restored.vendorHandoffs, [item])
        XCTAssertEqual(restored.visibleManual, [item])
    }

    func testConfirmedUpdateRemovesOnlyThisCopyAndRecordsExternalHistoryWithoutFullScan() async throws {
        let harness = harness()
        var dependencies = harness.store.dependencies
        dependencies.checkVendorUpdate = { _ in .init(app: selfApp(), outcome: .confirmed) }
        var entries: [UpdateJournalEntry] = []
        dependencies.recordUpdateRun = { entries.append($0) }
        var reportedCounts: [Int] = []
        dependencies.reportVendorCheck = { _, _, _, count, _ in reportedCounts.append(count) }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        let item = update()
        var copy = item
        copy.path = URL(fileURLWithPath: "/Other/Example.app")
        store.manualOutdated = [item, copy]
        store.lastCheck = timestamp
        store.status = .results
        await store.checkVendorUpdate(item)

        XCTAssertEqual(store.visibleManual, [copy])
        XCTAssertTrue(store.vendorHandoffs.isEmpty)
        XCTAssertEqual(store.lastCheck, timestamp)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.trigger, .external)
        XCTAssertEqual(entries.first?.upgradedCount, 1)
        XCTAssertEqual(reportedCounts, [1])
        let snapshot = try XCTUnwrap(ScanResultStore(io: harness.snapshots).load())
        XCTAssertEqual(snapshot.manual, [copy])
        XCTAssertTrue(snapshot.vendorHandoffs.isEmpty)
    }

    func testFailureKeepsRowAndDoesNotTurnOtherSourcesIntoFreshSuccess() async {
        let harness = harness()
        var dependencies = harness.store.dependencies
        dependencies.checkVendorUpdate = { _ in .init(app: selfApp(), outcome: .unconfirmed(.sourceUnavailable)) }
        dependencies.recordUpdateRun = { _ in XCTFail("An inconclusive check must not record an update") }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.lastCheck = timestamp
        store.manualOutdated = [update()]
        store.installationChecks = [InstallationCheck(app: selfApp(), sources: [
            .init(source: "Homebrew", outcome: .current), .init(source: "Sparkle", outcome: .outdated)
        ], checkedAt: timestamp)]
        await store.checkVendorUpdate(update())

        XCTAssertEqual(store.visibleManual, [update()])
        XCTAssertEqual(store.vendorHandoffs, [update()])
        XCTAssertNotNil(store.vendorMessages[update().path.path])
        XCTAssertEqual(store.installationChecks.first?.sources.first?.outcome, .notChecked)
        XCTAssertEqual(store.installationChecks.first?.sources.last?.outcome, .failed)
        XCTAssertEqual(store.installationChecks.first?.lastSuccessfulCheck, timestamp)
    }

    func testFailedLaunchDoesNotCreateHandoffAndDismissalDoesNotConfirm() {
        let harness = harness()
        let item = update()
        harness.store.vendorOpened(item, succeeded: false)
        XCTAssertTrue(harness.store.vendorHandoffs.isEmpty)
        XCTAssertNotNil(harness.store.vendorMessages[item.path.path])
        harness.store.vendorOpened(item, succeeded: true)
        harness.store.dismissVendorHandoff(item)
        XCTAssertTrue(harness.store.vendorHandoffs.isEmpty)
        XCTAssertEqual(harness.store.visibleManual, [item])
    }

    func testCancelledVerificationKeepsPendingRowAndClearsBusyState() async {
        let harness = harness()
        var dependencies = harness.store.dependencies
        dependencies.checkVendorUpdate = { _ in throw CancellationError() }
        dependencies.recordUpdateRun = { _ in XCTFail("Cancellation is not success") }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.lastCheck = timestamp
        store.manualOutdated = [update()]
        await store.checkVendorUpdate(update())
        XCTAssertNil(store.vendorCheckPath)
        XCTAssertEqual(store.vendorHandoffs, [update()])
        XCTAssertEqual(store.visibleManual, [update()])
    }

    func testSupersededCheckCannotRemoveRowOrRecordHistory() async {
        let harness = harness()
        var dependencies = harness.store.dependencies
        let gate = VendorVerificationGate()
        dependencies.checkVendorUpdate = { _ in
            await gate.suspend()
            return .init(app: selfApp(), outcome: .confirmed)
        }
        dependencies.recordUpdateRun = { _ in XCTFail("A newer full scan invalidated this result") }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.lastCheck = timestamp
        store.manualOutdated = [update()]
        let task = Task { await store.checkVendorUpdate(update()) }
        await gate.waitUntilStarted()
        store.vendorCheckGeneration += 1
        await gate.resume()
        await task.value
        XCTAssertEqual(store.visibleManual, [update()])
        XCTAssertNil(store.vendorCheckPath)
    }

    private var timestamp: Date { Date(timeIntervalSince1970: 1_000) }

    private func harness() -> ScanStoreRuntimeHarness {
        let runner = ScanStoreRuntimeProcessRunner { _ in
            XCTFail("A single-vendor check must never invoke a process")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner, manualScan: { _, _ in
            XCTFail("A single-vendor check must never run a full manual scan")
            return ([], 0)
        })
        harness.store.lastCheck = timestamp
        harness.store.status = .results
        harness.store.manualOutdated = [update()]
        return harness
    }

    private func update() -> ManualOutdatedApp {
        ManualOutdatedApp(name: "Example", path: selfApp().path, installedVersion: "1.0 (100)",
                          availableVersion: "1.0 (101)", source: .sparkle, bundleIdentifier: "com.example.app",
                          completionRequirement: .init(version: "101", field: .buildVersion, scheme: .numericBuild))
    }
}

private actor VendorVerificationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() { continuation?.resume(); continuation = nil }
}

private func selfApp() -> ApplicationInfo {
    ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                    bundleIdentifier: "com.example.app", version: "1.0", buildVersion: "101",
                    installDate: nil, updateDate: nil, isManagedByBrew: false)
}
