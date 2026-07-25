import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Operation coordinator regressions")
struct OperationCoordinatorRegressionTests {
    @Test func cancelledWaiterNeverStartsItsOperation() async throws {
        let coordinator = OperationCoordinator()
        let firstStarted = AsyncLatch()
        let releaseFirst = AsyncLatch()
        let cancelledOperationRan = AsyncFlag()

        let first = Task {
            await coordinator.withWrite(label: "first") {
                await firstStarted.open()
                await releaseFirst.wait()
            }
        }
        await firstStarted.wait()

        let cancelled = Task {
            try await coordinator.withWriteLease(label: "cancelled") { _ in
                await cancelledOperationRan.set()
            }
        }
        await waitForQueuedWrite(in: coordinator)
        cancelled.cancel()

        await releaseFirst.open()
        await first.value

        do {
            try await cancelled.value
            Issue.record("A cancelled waiter should finish with CancellationError")
        } catch is CancellationError {
            // Expected: cancellation removes the waiter without invoking its closure.
        }
        #expect(!(await cancelledOperationRan.value))
        #expect((await coordinator.snapshot()).queuedWrites == 0)
    }

    @Test func activeWriteLeaseAllowsNestedReadWithoutRequeueing() async throws {
        let coordinator = OperationCoordinator()

        let value = try await coordinator.withWriteLease(label: "outer") { lease in
            try await coordinator.withRead(holding: lease, label: "nested") {
                42
            }
        }

        #expect(value == 42)
        #expect((await coordinator.snapshot()).isIdle)
    }

    @Test func readLeaseRejectsNestedWriteInsteadOfDeadlocking() async throws {
        let coordinator = OperationCoordinator()

        do {
            _ = try await coordinator.withReadLease(label: "outer") { lease in
                try await coordinator.withWrite(holding: lease, label: "invalid nested write") {
                    42
                }
            }
            Issue.record("A read lease must not authorize a nested write")
        } catch let error as OperationCoordinator.LeaseError {
            #expect(error == .insufficientAccess)
        }
        #expect((await coordinator.snapshot()).isIdle)
    }

    @Test func expiredLeaseFailsFast() async throws {
        let coordinator = OperationCoordinator()
        let lease = try await coordinator.withReadLease(label: "outer") { $0 }

        do {
            _ = try await coordinator.withRead(holding: lease, label: "stale nested read") {
                42
            }
            Issue.record("A released lease must not authorize more work")
        } catch let error as OperationCoordinator.LeaseError {
            #expect(error == .expired)
        }
    }

    @Test func foreignLeaseFailsFast() async throws {
        let owner = OperationCoordinator()
        let foreign = OperationCoordinator()

        try await owner.withReadLease(label: "owner") { lease in
            do {
                _ = try await foreign.withRead(holding: lease, label: "foreign nested read") {
                    42
                }
                Issue.record("A lease must not cross coordinator boundaries")
            } catch let error as OperationCoordinator.LeaseError {
                #expect(error == .foreignCoordinator)
            }
        }
    }

    private func waitForQueuedWrite(in coordinator: OperationCoordinator) async {
        while (await coordinator.snapshot()).queuedWrites == 0 {
            await Task.yield()
        }
    }
}

private actor AsyncLatch {
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

private actor AsyncFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}
