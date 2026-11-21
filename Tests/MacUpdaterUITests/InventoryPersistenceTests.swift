import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Inventory keeps its result") @MainActor
struct InventoryPersistenceTests {
    @Test func aSecondVisitReusesTheResult() async {
        let store = InventoryStore(operations: OperationCoordinator(), now: { Date(timeIntervalSince1970: 100) })
        #expect(store.needsInitialRead)
        await store.scan(using: PersistenceLoader(apps: [application("Slack")]), onWegaState: nil)
        #expect(store.lastReadAt == Date(timeIntervalSince1970: 100) && !store.needsInitialRead)
    }

    @Test func aSecondVisitWithoutChangesReusesTheResultButAStaleOneRescans() async {
        let loader = CountingLoader()
        let store = InventoryStore(operations: OperationCoordinator())
        func visit() async { if store.needsInitialRead { await store.scan(using: loader, onWegaState: nil) } }

        await visit()
        await visit()
        #expect(await loader.loads == 1, "no change in between: the result is reused")

        store.markStale()
        #expect(!store.apps.isEmpty, "the list stays on screen while stale")
        #expect(store.isStale && store.needsInitialRead)
        await visit()
        #expect(await loader.loads == 2 && !store.isStale && !store.needsInitialRead)
    }

    @Test func aChangeDuringAReadIsNotForgotten() async {
        let store = InventoryStore(operations: OperationCoordinator())
        let loader = CountingLoader { store.markStale() }
        await store.scan(using: loader, onWegaState: nil)
        #expect(store.isStale && store.needsInitialRead)
    }

    @Test func everyAppSetChangeMarksTheInventoryStaleAndTheChecksShareOneGuard() throws {
        let content = try source("Sources/MacUpdater/ContentView.swift")
        #expect(content.contains("InventoryStalenessWatcher()"))
        let watcher = try source("Sources/MacUpdater/InventoryStalenessWatcher.swift")
        for literal in ["scan.updating", "cleanup.phase", "migration.migrating", "migration.duplicateBusyKey", "inventory.markStale()"] {
            #expect(watcher.contains(literal), "\(literal)")
        }
        let uninstall = try source("Sources/MacUpdater/UninstallView.swift")
        #expect(uninstall.contains("@EnvironmentObject private var inventory: InventoryStore") && uninstall.contains("inventory.markStale()"))
        #expect(try source("Sources/MacUpdater/UpdateView.swift").contains("isEnabled: scan.canStartCheck,"))
        let view = try source("Sources/MacUpdater/InventoryView.swift")
        #expect(view.contains("Button { scanStore.startCheck(); onNavigate?(.updates(.all)) }"))
    }

    @Test func aPartialReadStillCountsAsRead() async {
        let store = InventoryStore(operations: OperationCoordinator(), now: { Date(timeIntervalSince1970: 7) })
        let failure = ScanSourceFailure(source: .homebrew, message: "boom")
        await store.scan(using: PersistenceLoader(apps: [application("Slack")], failures: [failure]), onWegaState: nil)
        #expect(store.lastReadAt == Date(timeIntervalSince1970: 7) && store.errorMessage != nil)
    }

    @Test func anEmptyFilterIsNotALostInventoryAndAFailedReadIsNotEmpty() {
        #expect(InventoryEmptyState.of(appCount: 12, rowCount: 0, isScanning: false, hasError: false, lastReadAt: .now) == .noMatches)
        #expect(InventoryEmptyState.of(appCount: 0, rowCount: 0, isScanning: false, hasError: false, lastReadAt: .now) == .nothingRead)
        #expect(InventoryEmptyState.of(appCount: 0, rowCount: 0, isScanning: false, hasError: true, lastReadAt: .now) == nil, "the error banner speaks")
        #expect(InventoryEmptyState.of(appCount: 0, rowCount: 0, isScanning: true, hasError: false, lastReadAt: nil) == nil)
        #expect(InventoryEmptyState.of(appCount: 0, rowCount: 0, isScanning: false, hasError: false, lastReadAt: nil) == nil,
                "before the first read nothing is claimed")
        #expect(InventoryEmptyState.of(appCount: 3, rowCount: 2, isScanning: false, hasError: false, lastReadAt: .now) == nil)
        withLanguage(.en) {
            #expect(InventoryEmptyState.noMatches.message == "No apps match these filters.")
            #expect(tr("Wyczyść filtry") == "Clear Filters")
            #expect(InventoryEmptyState.nothingRead.message == "I found no apps in the selected folders. Check the scan folders or refresh the inventory.")
            #expect(tr("Odśwież spis") == "Refresh Inventory" && tr("Nie sprawdza nowych wersji") == "Does not check for new versions")
            #expect(trf("Odczytano %@", CheckedAtCopy.day(.now, now: .now)).hasPrefix("Read today, "))
        }
    }

    @Test func theCheckButtonWaitsForAnIdleScanStore() {
        let store = ScanStore()
        #expect(store.canStartCheck)
        store.updating = true
        #expect(!store.canStartCheck)
        store.updating = false
        store.status = .checking
        #expect(!store.canStartCheck)
    }

    @Test func theStoreLivesInTheAppAndTheViewDoesNotRescanOnEntry() throws {
        let app = try source("Sources/MacUpdater/MacUpdaterApp.swift")
        #expect(app.contains("@StateObject private var inventory = InventoryStore()") && app.contains(".environmentObject(inventory)"))
        let view = try source("Sources/MacUpdater/InventoryView.swift")
        #expect(view.contains("@EnvironmentObject private var inventory: InventoryStore"))
        #expect(!view.contains("@StateObject private var inventory"))
        #expect(view.contains("if inventory.needsInitialRead { await scan() }"))
        #expect(view.contains("scanStore.startCheck()") && view.contains(".disabled(!scanStore.canStartCheck)"))
        #expect(view.contains(".help(tr(\"Nie sprawdza nowych wersji\"))"))
        #expect(view.contains("@ObservedObject private var clock = DayClock.shared"))
    }

    private func application(_ name: String) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "uxp30.\(name)",
            version: "1",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private actor LoadCounter {
    var loads = 0
    func bump() { loads += 1 }
}

private struct CountingLoader: InventorySnapshotLoading {
    private let counter = LoadCounter()
    private let duringLoad: (@MainActor @Sendable () -> Void)?
    init(duringLoad: (@MainActor @Sendable () -> Void)? = nil) { self.duringLoad = duringLoad }
    var loads: Int { get async { await counter.loads } }
    func load() async -> InventorySnapshot {
        await counter.bump()
        if let duringLoad { await duringLoad() }
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: "uxp30.slack",
            version: "1", installDate: nil, updateDate: nil, isManagedByBrew: false
        )
        return InventorySnapshot(apps: [app], npmGlobals: [])
    }
}

private struct PersistenceLoader: InventorySnapshotLoading {
    let apps: [ApplicationInfo]
    var failures: [ScanSourceFailure] = []
    func load() async -> InventorySnapshot {
        InventorySnapshot(apps: apps, npmGlobals: [], failures: failures)
    }
}
