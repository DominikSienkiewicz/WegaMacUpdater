import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Shared inventory footprint measurement") @MainActor
struct InventorySharedMeasurementTests {
    @Test func closingOneWindowKeepsTheOtherWindowsMeasurement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        await fixture.refresh()
        let read = try #require(store.lastReadAt)
        let first = Task { await store.measureFootprints(for: read) }
        await fixture.reader.waitForFirstCall()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let second = Task {
            signal.yield()
            await store.measureFootprints(for: read)
        }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        first.cancel()
        await fixture.reader.releaseFirstCall()
        await first.value
        await second.value

        #expect(await fixture.reader.calls == 1)
        #expect(await !fixture.reader.firstCallWasCancelled)
        #expect(store.footprintMeasurement?.readAt == read)
        #expect(store.footprintMeasurement?.saved == true)
        #expect(store.footprintFailureRead == nil)
    }

    @Test func refreshingSupersedesAnUnfinishedMeasurement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.refresh()
        let oldRead = try #require(fixture.store.lastReadAt)
        let old = Task { await fixture.store.measureFootprints(for: oldRead) }
        await fixture.reader.waitForFirstCall()

        await fixture.refresh()
        let newRead = try #require(fixture.store.lastReadAt)
        await fixture.store.measureFootprints(for: newRead)
        await fixture.reader.releaseFirstCall()
        await old.value

        #expect(newRead != oldRead)
        #expect(await fixture.reader.calls == 2)
        #expect(await fixture.reader.firstCallWasCancelled)
        #expect(fixture.store.footprintMeasurement?.readAt == newRead)
        #expect(fixture.store.footprintMeasurement?.previousDate == nil)
    }
}

@MainActor
private final class Fixture {
    let reader: PausedReader
    let store: InventoryStore
    private let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)

    init() throws {
        let reader = PausedReader()
        self.reader = reader
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tick: TimeInterval = 0
        store = InventoryStore(
            operations: OperationCoordinator(),
            footprintHistory: InventoryFootprintHistory(fileURL: directory.appending(component: "history.json")),
            footprintReader: reader,
            now: { tick += 1; return Date(timeIntervalSince1970: tick) }
        )
    }

    func refresh() async {
        await store.scan(using: CountingInventoryLoader(), changes: InventoryChangeStamp(), onWegaState: nil)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private actor PausedReader: InventoryFootprintReading {
    private(set) var calls = 0
    private(set) var firstCallWasCancelled = false
    private var firstStarted: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var finishedFirst: CheckedContinuation<Void, Never>?

    func measure(_ apps: [ApplicationInfo]) async throws -> [InstallationIdentity: InventoryFootprint] {
        calls += 1
        if calls == 1 {
            firstStarted?.resume()
            await withCheckedContinuation { release = $0 }
            firstCallWasCancelled = Task.isCancelled
            finishedFirst?.resume()
            try Task.checkCancellation()
        }
        return [:]
    }

    func waitForFirstCall() async {
        if calls == 0 { await withCheckedContinuation { firstStarted = $0 } }
    }

    func releaseFirstCall() async {
        release?.resume()
        await withCheckedContinuation { finishedFirst = $0 }
    }
}
