import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Undo policy across scan routes")
@MainActor
struct UndoPolicyRouteTests {
    @Test func anOlderVendorHandoffCannotOverrideTheNewlyResolvedCaskPin() {
        let token = "handoff-policy-\(UUID().uuidString)"
        let key = UpdatePlanner.key(name: token, kind: .cask)
        defer { UpdatePolicyStore.shared.remove(key: key) }
        let runner = ScanStoreRuntimeProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "{}", stderr: "") }
        let store = makeScanStoreRuntimeHarness(runner: runner).store
        let path = URL(fileURLWithPath: "/Applications/Example.app")
        let app = ApplicationInfo(path: path, name: "Example", bundleIdentifier: "com.example.app",
                                  version: "1.0", installDate: nil, updateDate: nil, isManagedByBrew: true)
        let old = ManualOutdatedApp(name: app.name, path: path, installedVersion: "1.0", availableVersion: "2.0",
                                    source: .sparkle, bundleIdentifier: app.bundleIdentifier)
        var fresh = old
        fresh.caskPolicyToken = token
        var check = InstallationCheck(app: app, sources: [], checkedAt: Date())
        check.caskToken = token
        store.manualOutdated = [fresh]
        store.vendorHandoffs = [old]
        store.installationChecks = [check]
        UpdatePolicyStore.shared.pin(key: key, name: app.name, version: "1.0")

        #expect(store.visibleManual.isEmpty)
        UpdatePolicyStore.shared.remove(key: key)
        #expect(store.visibleManual.first?.caskPolicyToken == token)
        #expect(store.visibleManual.count == 1)
    }

    @Test func thePinCreatedByUndoSuppressesTheNextMetadataRepairRow() async throws {
        let token = "undo-policy-\(UUID().uuidString)"
        let root = try makeScanStoreRuntimeTemporaryDirectory("undo-policy-route")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let bundleID = "example.undo.\(UUID().uuidString)"
        try makeScanStoreRuntimeApp(at: app, bundleIdentifier: bundleID, version: "1.0", payload: "before")
        let operation = try makeScanStoreRuntimeUndoOperation(token: token, appURL: app, copySnapshot: true)
        defer { UpdateOperationStore.shared.removeOperation(id: operation.operationID) }
        let key = UpdatePlanner.key(name: token, kind: .cask)
        defer { UpdatePolicyStore.shared.remove(key: key) }
        try makeScanStoreRuntimeApp(at: app, bundleIdentifier: bundleID, version: "2.0", payload: "after")
        let runner = ScanStoreRuntimeProcessRunner { request in
            let output = request.arguments.first == "outdated" && request.arguments.contains("--json=v2")
                ? "{\"formulae\":[],\"casks\":[]}" : "{}"
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)

        await harness.store.undoUpdate(operation.undoable)

        let installed = ApplicationInfo(
            path: app, name: "Example", bundleIdentifier: bundleID, version: "1.0",
            installDate: nil, updateDate: nil, isManagedByBrew: true, caskToken: token
        )
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [installed], brewCaskVersions: [token: "2.0"], alreadyListedTokens: []
        )
        #expect(rows.count == 1)
        let associated = UpdatePlanner.attachingCaskPolicies(to: rows, appPaths: [token: app])
        #expect(UpdatePlanner.applyPolicies(associated, policies: UpdatePolicyStore.shared.policiesMap).isEmpty)
        UpdatePolicyStore.shared.remove(key: key)
        #expect(UpdatePlanner.applyPolicies(associated, policies: UpdatePolicyStore.shared.policiesMap).count == 1)
    }
}
