import Testing

@testable import MacUpdaterCore

@Suite("Operation coordinator nested lifetime")
struct OperationCoordinatorNestedLifetimeTests {
    @Test func detachedNestedReadKeepsTheOuterWriteLeaseActive() async throws {
        let coordinator = OperationCoordinator()
        let nestedStarted = NestedLifetimeLatch()
        let releaseNested = NestedLifetimeLatch()
        let writerRan = NestedLifetimeFlag()

        let nested = try await coordinator.withWriteLease(label: "outer write") { lease in
            let child = Task.detached {
                try await coordinator.withRead(holding: lease, label: "detached nested read") {
                    await nestedStarted.open()
                    await releaseNested.wait()
                }
            }
            await nestedStarted.wait()
            return child
        }

        let writer = Task {
            await coordinator.withWrite(label: "conflicting writer") {
                await writerRan.set()
            }
        }
        while !(await writerRan.value), (await coordinator.snapshot()).queuedWrites == 0 {
            await Task.yield()
        }

        #expect(!(await writerRan.value))
        #expect((await coordinator.snapshot()).activeWrite == "outer write")

        await releaseNested.open()
        try await nested.value
        await writer.value

        #expect(await writerRan.value)
        #expect((await coordinator.snapshot()).isIdle)
    }
}

private actor NestedLifetimeLatch {
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

private actor NestedLifetimeFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}
