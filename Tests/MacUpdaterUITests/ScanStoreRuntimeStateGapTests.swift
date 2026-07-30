import Foundation
import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

@MainActor
final class ScanStoreRuntimeStateGapTests: XCTestCase {
    private enum StubError: Error {
        case unexpected([String])
    }

    func testIncompleteSnapshotRestoreAndInterruptedRunPublishTheirWarnings() throws {
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        let scannedAt = Date(timeIntervalSince1970: 4_000_000_000)
        let reports = ScanSourceReports(
            brew: ScanSourceReport(outcome: .failed("offline"), error: "brew offline"),
            mas: ScanSourceReport(outcome: .succeeded),
            npm: ScanSourceReport(outcome: .succeeded),
            manual: ScanSourceReport(outcome: .succeeded)
        )
        try ScanResultStore(io: harness.snapshots).save(ScanSnapshot(
            scannedAt: scannedAt,
            brew: nil,
            mas: [],
            npm: [],
            manual: [],
            sources: reports
        ))

        harness.store.restoreLastScan()

        XCTAssertEqual(harness.store.status, .results)
        XCTAssertEqual(harness.store.lastCheck, scannedAt)
        XCTAssertFalse(harness.store.lastScanComplete)
        XCTAssertEqual(harness.store.banner?.action, .openLogs)
        harness.store.restoreLastScan()

        harness.store.dismissBanner()
        harness.store.updating = true
        harness.store.cancelUpdate()
        XCTAssertTrue(harness.store.shouldStopUpdate(before: ["first", "second"]))
        harness.store.reportInterruptedRun(upgraded: 1)

        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertTrue(harness.store.updateInterruption.isRequested)
        XCTAssertEqual(harness.store.updateInterruption.skippedKeys, ["first", "second"])
        harness.store.resetUpdateInterruption()
        XCTAssertFalse(harness.store.updateInterruption.isRequested)
        XCTAssertFalse(harness.store.shouldStopUpdate(before: ["third"]))
    }

    func testPoliciesAndInspectorExerciseOutdatedManualAndMissingBranches() throws {
        let first = "ignored-formula-\(UUID().uuidString)"
        let second = "skipped-formula-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [
                BrewOutdatedItem(name: first, installedVersions: ["1"], currentVersion: "2"),
                BrewOutdatedItem(name: second, installedVersions: ["1"], currentVersion: "2"),
            ],
            casks: []
        )
        let ignoredManual = ManualOutdatedApp(
            name: "Ignored Manual",
            path: URL(fileURLWithPath: "/Applications/Ignored-\(UUID().uuidString).app"),
            installedVersion: "1",
            availableVersion: "2",
            source: .sparkle,
            bundleIdentifier: "example.ignored.\(UUID().uuidString)"
        )
        let skippedManual = ManualOutdatedApp(
            name: "Skipped Manual",
            path: URL(fileURLWithPath: "/Applications/Skipped-\(UUID().uuidString).app"),
            installedVersion: "1",
            availableVersion: "2",
            source: .sparkle,
            bundleIdentifier: "example.skipped.\(UUID().uuidString)"
        )
        harness.store.manualOutdated = [ignoredManual, skippedManual]
        let items = harness.store.allItems
        let ignoredItem = try XCTUnwrap(items.first { $0.name == first })
        let skippedItem = try XCTUnwrap(items.first { $0.name == second })
        let policyKeys = [
            ignoredItem.policyKey,
            skippedItem.policyKey,
            ignoredManual.policyKey,
            skippedManual.policyKey,
        ]
        defer { policyKeys.forEach(UpdatePolicyStore.shared.remove(key:)) }

        harness.store.inspectedKey = ignoredItem.key
        if case .outdated(let inspected, _) = try XCTUnwrap(harness.store.inspectedUpdate) {
            XCTAssertEqual(inspected, ignoredItem)
        } else {
            XCTFail("expected an outdated inspector result")
        }
        harness.store.inspectedKey = "missing:\(UUID().uuidString)"
        XCTAssertNil(harness.store.inspectedUpdate)

        harness.store.selected = [ignoredItem.key, skippedItem.key]
        harness.store.ignoreItem(ignoredItem)
        harness.store.ignoreManual(ignoredManual)
        harness.store.skipItem(skippedItem)
        harness.store.skipManual(skippedManual)

        XCTAssertFalse(harness.store.selected.contains(ignoredItem.key))
        XCTAssertFalse(harness.store.selected.contains(skippedItem.key))
        XCTAssertEqual(UpdatePolicyStore.shared.policy(for: ignoredItem.policyKey), .ignored)
        XCTAssertEqual(
            UpdatePolicyStore.shared.policy(for: skippedItem.policyKey),
            .skipped(version: "2")
        )
        XCTAssertEqual(UpdatePolicyStore.shared.policy(for: ignoredManual.policyKey), .ignored)
        XCTAssertEqual(
            UpdatePolicyStore.shared.policy(for: skippedManual.policyKey),
            .skipped(version: "2")
        )

        let noVersion = OutdatedItem(
            key: "f:no-version-\(UUID().uuidString)",
            name: "No Version",
            from: "1",
            to: nil,
            kind: .formula
        )
        let noManualVersion = ManualOutdatedApp(
            name: "No Manual Version",
            path: URL(fileURLWithPath: "/Applications/NoVersion-\(UUID().uuidString).app"),
            installedVersion: "1",
            availableVersion: nil,
            source: .sparkle
        )
        harness.store.skipItem(noVersion)
        harness.store.skipManual(noManualVersion)
        XCTAssertNil(UpdatePolicyStore.shared.policy(for: noVersion.policyKey))
        XCTAssertNil(UpdatePolicyStore.shared.policy(for: noManualVersion.policyKey))
    }

    func testUndoHandlesMissingJournalAndMissingSnapshotWithoutTouchingAnApp() async throws {
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        let missingJournal = UndoableUpdate(
            operationID: UUID(),
            token: "missing-journal",
            appPath: "/Applications/Missing.app",
            restoredVersion: "1",
            updatedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )

        await harness.store.undoUpdate(missingJournal)
        XCTAssertNil(harness.store.undoBusy)

        let missingFiles = try makeScanStoreRuntimeUndoOperation(
            token: "missing-files-\(UUID().uuidString)",
            appURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString).app"),
            copySnapshot: false
        )
        defer { UpdateOperationStore.shared.removeOperation(id: missingFiles.operationID) }

        await harness.store.undoUpdate(missingFiles.undoable)

        XCTAssertNil(harness.store.undoBusy)
        XCTAssertNil(harness.store.banner)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testUndoRestoresSnapshotPinsVersionAndRunsALightweightRescan() async throws {
        let token = "undo-success-\(UUID().uuidString)"
        let root = try makeScanStoreRuntimeTemporaryDirectory("scan-store-undo")
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Undo.app", isDirectory: true)
        let bundleIdentifier = "example.undo.\(UUID().uuidString)"
        try makeScanStoreRuntimeApp(
            at: appURL,
            bundleIdentifier: bundleIdentifier,
            version: "1.0",
            payload: "trusted"
        )
        let operation = try makeScanStoreRuntimeUndoOperation(
            token: token,
            appURL: appURL,
            copySnapshot: true
        )
        defer { UpdateOperationStore.shared.removeOperation(id: operation.operationID) }
        let policyKey = UpdatePlanner.key(name: token, kind: .cask)
        defer { UpdatePolicyStore.shared.remove(key: policyKey) }
        try makeScanStoreRuntimeApp(
            at: appURL,
            bundleIdentifier: bundleIdentifier,
            version: "2.0",
            payload: "bad update"
        )
        let runner = ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
            case ["outdated"]:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            case ["outdated", "-g", "--json"]:
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            default:
                throw StubError.unexpected(request.arguments)
            }
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)

        await harness.store.undoUpdate(operation.undoable)

        XCTAssertNil(harness.store.undoBusy)
        XCTAssertEqual(harness.store.banner?.variant, .success)
        XCTAssertEqual(UpdatePolicyStore.shared.policy(for: policyKey), .pinned(version: "1.0"))
        let restoredPlist = try Data(
            contentsOf: appURL.appendingPathComponent("Contents/Info.plist")
        )
        let restoredValues = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: restoredPlist, format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(restoredValues["CFBundleShortVersionString"] as? String, "1.0")
        XCTAssertTrue(runner.requests.contains {
            $0.arguments == [
                "outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates",
            ]
        })
    }
}
