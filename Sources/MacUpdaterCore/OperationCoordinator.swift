import Foundation

/// A fair, process-wide read/write boundary for Homebrew and filesystem operations.
///
/// Reads may overlap while writes are exclusive. Once a write is queued, later reads
/// wait behind it so periodic scans cannot starve a user-initiated mutation.
public actor OperationCoordinator {
    public static let shared = OperationCoordinator()

    public enum Access: Sendable {
        case read
        case write
    }

    public struct Snapshot: Equatable, Sendable {
        public let activeReads: Int
        public let activeWrite: String?
        public let queuedReads: Int
        public let queuedWrites: Int

        public var isWriting: Bool { activeWrite != nil }
        public var isIdle: Bool { activeReads == 0 && activeWrite == nil }
    }

    private struct Waiter {
        let access: Access
        let label: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeReads = 0
    private var activeWrite: String?
    private var waiters: [Waiter] = []

    public init() {}

    public func snapshot() -> Snapshot {
        Snapshot(
            activeReads: activeReads,
            activeWrite: activeWrite,
            queuedReads: waiters.count { $0.access == .read },
            queuedWrites: waiters.count { $0.access == .write }
        )
    }

    public func withRead<Result: Sendable>(
        label: String,
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        try await withOperation(access: .read, label: label, operation: operation)
    }

    public func withWrite<Result: Sendable>(
        label: String,
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        try await withOperation(access: .write, label: label, operation: operation)
    }

    private func withOperation<Result: Sendable>(
        access: Access,
        label: String,
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        await acquire(access: access, label: label)
        defer { release(access: access) }
        return try await operation()
    }

    private func acquire(access: Access, label: String) async {
        if canStartImmediately(access) {
            start(access: access, label: label)
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(access: access, label: label, continuation: continuation))
        }
    }

    private func canStartImmediately(_ access: Access) -> Bool {
        guard waiters.isEmpty, activeWrite == nil else { return false }
        switch access {
        case .read:
            return true
        case .write:
            return activeReads == 0
        }
    }

    private func start(access: Access, label: String) {
        switch access {
        case .read:
            activeReads += 1
        case .write:
            activeWrite = label
        }
    }

    private func release(access: Access) {
        switch access {
        case .read:
            activeReads -= 1
        case .write:
            activeWrite = nil
        }
        drainWaitersIfPossible()
    }

    private func drainWaitersIfPossible() {
        guard activeReads == 0, activeWrite == nil, !waiters.isEmpty else { return }

        if waiters[0].access == .write {
            let waiter = waiters.removeFirst()
            start(access: waiter.access, label: waiter.label)
            waiter.continuation.resume()
            return
        }

        while !waiters.isEmpty, waiters[0].access == .read {
            let waiter = waiters.removeFirst()
            start(access: waiter.access, label: waiter.label)
            waiter.continuation.resume()
        }
    }
}
