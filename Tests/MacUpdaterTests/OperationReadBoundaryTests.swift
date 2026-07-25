import Testing
@testable import MacUpdaterCore

@Suite("Operation read boundaries")
struct OperationReadBoundaryTests {
    @Test func menuBarScanHoldsAReadLeaseForItsWholeRound() async {
        let operations = OperationCoordinator()
        let brew = BlockingBrewRead()
        let writerRan = ReadBoundaryFlag()
        let checker = MenuBarUpdateChecker(
            brewService: brew,
            masService: EmptyMasRead(),
            npmService: EmptyNpmRead(),
            scanner: EmptyManualRead(),
            operations: operations
        )

        let scan = Task { await checker.availableUpdateCount() }
        await brew.waitUntilStarted()

        let writer = Task {
            await operations.withWrite(label: "writer") {
                await writerRan.set()
            }
        }
        while (await operations.snapshot()).queuedWrites == 0 {
            await Task.yield()
        }
        #expect(!(await writerRan.value))

        await brew.finish()
        _ = await scan.value
        await writer.value
        #expect(await writerRan.value)
    }
}

private actor BlockingBrewRead: BrewOutdatedProviding {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func outdatedGreedy() async throws -> BrewOutdated {
        started = true
        let pending = startWaiters
        startWaiters.removeAll()
        pending.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return BrewOutdated(formulae: [], casks: [])
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct EmptyMasRead: MasOutdatedProviding {
    func outdated() async throws -> [MasOutdatedApp] { [] }
}

private struct EmptyNpmRead: NpmOutdatedProviding {
    func outdated() async throws -> [NpmGlobalOutdated] { [] }
}

private struct EmptyManualRead: ManualScanning {
    func scan(brewOutdatedCasks _: Set<String>) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        ([], 0)
    }
}

private actor ReadBoundaryFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}
