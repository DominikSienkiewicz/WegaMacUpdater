import Foundation
import MacUpdaterCore
import Testing
import WegaTestSupport
@testable import WegaMacUpdater

/// UXP-30 (final review I1) — an update run, a background round, a migration or a Cleanup removal
/// can finish while the window is closed, and nothing in a view is there to see it. The stores that
/// run them count each one; the inventory compares those counts with the ones its last read started
/// from, so the next entry reads again after any of them and reuses the result otherwise.
@Suite("Inventory notices changes made with the window closed") @MainActor
struct InventoryStalenessTests {
    @Test func aCountedChangeSinceTheLastReadMakesTheNextEntryReadAgain() async {
        let store = InventoryStore(operations: OperationCoordinator())
        let loader = CountingInventoryLoader()
        var counts = InventoryChangeStamp()
        await enterInventory(store, using: loader, changes: counts)
        await enterInventory(store, using: loader, changes: counts)
        #expect(await loader.reads == 1, "nothing changed: the result is reused")
        #expect(!store.isStale(given: counts))

        let fields: [WritableKeyPath<InventoryChangeStamp, Int>] = [\.updateRuns, \.migrations, \.cleanupRemovals, \.backgroundInstalls, \.manualInstalls, \.undos]
        for field in fields {
            counts[keyPath: field] += 1
            #expect(store.isStale(given: counts) && store.needsRead(given: counts), "\(field)")
            await enterInventory(store, using: loader, changes: counts)
            #expect(!store.isStale(given: counts), "the read took in \(field)")
        }
        #expect(await loader.reads == 7)
    }

    @Test func aChangeThatLandsDuringAReadKeepsTheListStale() async {
        let store = InventoryStore(operations: OperationCoordinator())
        await store.scan(using: CountingInventoryLoader(), changes: InventoryChangeStamp(), onWegaState: nil)
        #expect(store.isStale(given: InventoryChangeStamp(updateRuns: 1)),
                "the read started before the run ended, so it cannot vouch for what the run changed")
    }

    @Test func anUpdateRunThatEndsWithNoWindowMakesTheNextEntryReadAgain() async {
        let harness = makeScanStoreRuntimeHarness(runner: Self.idleBrew())
        let scan = harness.store
        let inventory = InventoryStore(operations: OperationCoordinator())
        let loader = CountingInventoryLoader()
        func counts() -> InventoryChangeStamp { InventoryChangeStamp(updateRuns: scan.completedRunCount) }
        await enterInventory(inventory, using: loader, changes: counts())

        let formula = "staleness-formula-\(UUID().uuidString)"
        scan.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")], casks: []
        )
        await scan.runUpdate(targetKeys: [UpdatePlanner.key(name: formula, kind: .formula)])

        #expect(scan.completedRunCount == 1)
        #expect(inventory.isStale(given: counts()))
        await enterInventory(inventory, using: loader, changes: counts())
        await enterInventory(inventory, using: loader, changes: counts())
        #expect(await loader.reads == 2, "one new read after the run, then the result is reused")
    }

    @Test func aRunTurnedAwayBeforeItStartsChangesNothing() async {
        let harness = makeScanStoreRuntimeHarness(runner: Self.idleBrew())
        let scan = harness.store
        let formula = "staleness-busy-\(UUID().uuidString)"
        scan.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")], casks: []
        )
        let lock = scan.dependencies.upgradeMutex
        #expect(lock.acquire())
        defer { lock.release() }

        await scan.runUpdate(targetKeys: [UpdatePlanner.key(name: formula, kind: .formula)])

        #expect(scan.completedRunCount == 0, "a background upgrade held the lock: brew never ran")
    }

    @Test func aBackgroundRoundCountsOnlyWhenItInstalledSomething() async {
        let (defaults, teardown) = TestDefaults.isolated("inventory-staleness-agent")
        defer { teardown() }
        let agent = MenuBarAgent(defaults: defaults)
        let inventory = InventoryStore(operations: OperationCoordinator())
        let loader = CountingInventoryLoader()
        func counts() -> InventoryChangeStamp { InventoryChangeStamp(backgroundInstalls: agent.installedRoundCount) }
        await enterInventory(inventory, using: loader, changes: counts())

        agent.recordBackgroundRound(upgraded: [])
        #expect(agent.installedRoundCount == 0 && !inventory.needsRead(given: counts()))

        agent.recordBackgroundRound(upgraded: ["slack", "zoom"])
        #expect(agent.installedRoundCount == 1)
        #expect(inventory.isStale(given: counts()) && inventory.needsRead(given: counts()))
    }

    @Test func theAgentCountsTheRoundStraightAfterTheBackgroundUpdater() throws {
        let agent = try source("Sources/MacUpdater/MenuBarAgent.swift")
        let round = try #require(agent.range(of: "let upgraded = await BackgroundUpdater.shared.runIfEligible(")).upperBound
        #expect(agent[round...].prefix(200).contains("recordBackgroundRound(upgraded: upgraded)"))
    }

    @Test func aManualInstallTurnedAwayByTheLockCountsNothing() async throws {
        let harness = makeScanStoreRuntimeHarness(runner: Self.idleBrew())
        let token = "staleness-manual-\(UUID().uuidString)"
        harness.store.manualOutdated = [ManualOutdatedApp(
            name: token, path: URL(fileURLWithPath: "/TestApplications/\(token).app"),
            installedVersion: "1", availableVersion: "2", source: .cask(token: token)
        )]
        let lock = harness.store.dependencies.upgradeMutex
        #expect(lock.acquire())
        defer { lock.release() }
        await harness.store.installManual(token: token)
        await harness.store.reinstallManual(token: token)
        #expect(harness.store.completedManualInstallCount == 0, "brew never ran")
    }

    @Test func anUndoRefusedBeforeTheRestoreCountsNothing() async {
        let harness = makeScanStoreRuntimeHarness(runner: Self.idleBrew())
        let token = "missing-\(UUID().uuidString)"
        await harness.store.undoUpdate(UndoableUpdate(
            operationID: UUID(), token: token, appPath: "/TestApplications/\(token).app",
            restoredVersion: "1", updatedAt: .now, expiresAt: .now.addingTimeInterval(60)
        ))
        #expect(harness.store.completedUndoCount == 0)
    }

    @Test func theInstallAndTheUndoCountOnceTheirProcessRan() throws {
        let adoption = try source("Sources/MacUpdater/ScanStore+Adoption.swift")
        let drain = try #require(adoption.range(of: "exitCode = try await ProcessEventStream.drain(stream) { chunk in"))
        let count = try #require(adoption.range(of: "countManualInstall()"))
        let record = try #require(adoption.range(of: "UpdateDiagnostics.record(\"adoption.executionResult\""))
        #expect(drain.upperBound < count.lowerBound && count.upperBound < record.lowerBound)
        let undo = try source("Sources/MacUpdater/ScanStore+Undo.swift")
        let restore = try #require(undo.range(of: "let restored = await CaskRollbackGuard.restoreSnapshot(snapshotURL, to: appURL, token: undoable.token)"))
        let counted = try #require(undo.range(of: "countUndo()"))
        let guarded = try #require(undo.range(of: "guard restored else {"))
        #expect(restore.upperBound < counted.lowerBound && counted.upperBound < guarded.lowerBound)
    }

    /// `brew upgrade` succeeds and every listing comes back empty, so the rescan confirms the run.
    static func idleBrewRunner() -> ScanStoreRuntimeProcessRunner { idleBrew() }

    static func idleBrew() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner { request in
            let output = request.arguments.contains("--json=v2") ? #"{"formulae":[],"casks":[]}"#
                : request.arguments.contains("--json") ? "{}" : ""
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        }
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
