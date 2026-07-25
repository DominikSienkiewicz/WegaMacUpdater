import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Upgrade coordinator cancellation state")
@MainActor
struct UpgradeCoordinatorCancellationStateTests {
    @Test func cancellingAQueuedRequestRestoresIdleState() async {
        let operations = OperationCoordinator()
        let upgrades = UpgradeCoordinator(operations: operations)
        let blockerStarted = UpgradeStateLatch()
        let releaseBlocker = UpgradeStateLatch()

        let blocker = Task {
            await operations.withWrite(label: "external writer") { @MainActor in
                blockerStarted.open()
                await releaseBlocker.wait()
            }
        }
        await blockerStarted.wait()

        let queued = Task {
            try await upgrades.performWrite(.selfUpdate) { () async throws -> Bool in
                true
            }
        }
        while (await operations.snapshot()).queuedWrites == 0 {
            await Task.yield()
        }
        #expect(upgrades.state == .waiting(.selfUpdate))

        queued.cancel()
        do {
            _ = try await queued.value
            Issue.record("A cancelled queued request should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }

        #expect(upgrades.state == .idle)
        releaseBlocker.open()
        await blocker.value
    }
}

@MainActor
private final class UpgradeStateLatch {
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
