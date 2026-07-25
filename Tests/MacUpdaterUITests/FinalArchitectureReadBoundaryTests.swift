import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Final architecture read boundaries")
@MainActor
struct FinalArchitectureReadBoundaryTests {
    @Test func consentMetadataReaderHoldsTheReadGateForTheWholeSnapshot() async throws {
        let operations = OperationCoordinator()
        let provider = BlockingConsentMetadataProvider()
        let reader = BackgroundUpdateConsentMetadataReader(
            provider: provider,
            operations: operations
        )
        let writerRan = ArchitectureReadFlag()

        let read = Task { try await reader.read(tokens: ["iterm2"]) }
        await provider.waitUntilStarted()

        let writer = Task {
            await operations.withWrite(label: "writer") {
                await writerRan.set()
            }
        }
        await waitForQueuedWriter(in: operations)
        #expect(!(await writerRan.value))

        await provider.finish()
        _ = try await read.value
        await writer.value
        #expect(await writerRan.value)
    }

    @Test func inventoryStoreHoldsTheReadGateForItsWholeScan() async {
        let operations = OperationCoordinator()
        let expected = InventorySnapshot(
            apps: [application()],
            npmGlobals: [NpmGlobalPackage(name: "typescript", installedVersion: "6.0.0")]
        )
        let loader = BlockingInventorySnapshotLoader(snapshot: expected)
        let store = InventoryStore(operations: operations)
        let writerRan = ArchitectureReadFlag()

        let scan = Task {
            await store.scan(using: loader, onWegaState: nil)
        }
        await loader.waitUntilStarted()

        let writer = Task {
            await operations.withWrite(label: "writer") {
                await writerRan.set()
            }
        }
        await waitForQueuedWriter(in: operations)
        #expect(store.isScanning)
        #expect(!(await writerRan.value))

        await loader.finish()
        await scan.value
        await writer.value

        #expect(store.apps == expected.apps)
        #expect(store.npmGlobals == expected.npmGlobals)
        #expect(!store.isScanning)
        #expect(await writerRan.value)
    }

    private func waitForQueuedWriter(in operations: OperationCoordinator) async {
        while (await operations.snapshot()).queuedWrites == 0 {
            await Task.yield()
        }
    }

    private func application() -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Architecture Test.app"),
            name: "Architecture Test",
            bundleIdentifier: "example.architecture-test",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: true,
            caskToken: "architecture-test"
        )
    }
}

private actor BlockingConsentMetadataProvider: BackgroundUpdateConsentMetadataProviding {
    private let started = ArchitectureReadLatch()
    private let release = ArchitectureReadLatch()

    func caskArtifactProfiles(tokens _: [String]) async throws -> [CaskArtifactProfile] {
        await started.open()
        await release.wait()
        return []
    }

    func caskDownloadInfo(tokens _: [String]) async throws -> [CaskDownloadInfo] { [] }

    func outdatedGreedy() async throws -> BrewOutdated {
        BrewOutdated(formulae: [], casks: [])
    }

    func caskInstallationInfo(tokens _: [String]) async throws -> [BrewCaskInstallationInfo] {
        []
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func finish() async {
        await release.open()
    }
}

private actor BlockingInventorySnapshotLoader: InventorySnapshotLoading {
    private let snapshot: InventorySnapshot
    private let started = ArchitectureReadLatch()
    private let release = ArchitectureReadLatch()

    init(snapshot: InventorySnapshot) {
        self.snapshot = snapshot
    }

    func load() async -> InventorySnapshot {
        await started.open()
        await release.wait()
        return snapshot
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func finish() async {
        await release.open()
    }
}

private actor ArchitectureReadLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ArchitectureReadFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}
