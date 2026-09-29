import Foundation

/// A fair, process-wide read/write boundary for Homebrew and filesystem operations.
///
/// Reads may overlap while writes are exclusive. Once a write is queued, later reads
/// wait behind it so periodic scans cannot starve a user-initiated mutation.
public actor OperationCoordinator {
    public static let shared = OperationCoordinator(pendingInstallationStore: .shared)

    public enum Access: Sendable {
        case read
        case write
    }

    public enum LeaseError: Error, Equatable, Sendable, LocalizedError {
        case foreignCoordinator
        case expired
        case insufficientAccess
        case externalInstallationPending

        public var errorDescription: String? {
            guard self == .externalInstallationPending else { return nil }
            return "Wynik instalacji jest nieznany. Dalsze zmiany są zablokowane — sprawdź stan instalacji w Ustawieniach."
        }
    }

    /// Explicit proof that the caller already owns this coordinator's read or write slot.
    /// A write lease may authorize nested reads or writes; a read lease only nested reads.
    public struct Lease: Sendable {
        fileprivate let coordinatorID: UUID
        fileprivate let operationID: UUID
        fileprivate let access: Access
    }

    public struct Snapshot: Equatable, Sendable {
        public let activeReads: Int
        public let activeWrite: String?
        public let queuedReads: Int
        public let queuedWrites: Int
        public let externalInstallationPending: Bool

        public var isWriting: Bool { activeWrite != nil || externalInstallationPending }
        public var isIdle: Bool { activeReads == 0 && activeWrite == nil && !externalInstallationPending }
    }

    private struct Waiter {
        let id: UUID
        let access: Access
        let label: String
        let continuation: CheckedContinuation<Lease?, Never>
    }

    private struct ActiveOperation {
        let access: Access
        var rootReleased = false
        var nestedOperations = 0
    }

    private let coordinatorID = UUID()
    private var activeReads = 0
    private var activeWrite: String?
    private var activeOperations: [UUID: ActiveOperation] = [:]
    private var waiters: [Waiter] = []
    private let pendingInstallationStore: PendingHelperInstallationStore?

    public init(pendingInstallationStore: PendingHelperInstallationStore? = nil) {
        self.pendingInstallationStore = pendingInstallationStore
    }

    public nonisolated var hasUnresolvedExternalMutation: Bool { pendingInstallationStore?.hasPending == true }

    public func snapshot() -> Snapshot {
        Snapshot(
            activeReads: activeReads,
            activeWrite: activeWrite,
            queuedReads: waiters.count { $0.access == .read },
            queuedWrites: waiters.count { $0.access == .write },
            externalInstallationPending: hasUnresolvedExternalMutation
        )
    }

    /// Source-compatible convenience for nonthrowing, Void read operations.
    /// Cancellation while queued returns without invoking `operation`.
    public func withRead(
        label: String,
        operation: @Sendable () async -> Void
    ) async {
        await withVoidOperation(access: .read, label: label, operation: operation)
    }

    /// Source-compatible convenience for nonthrowing, Void write operations.
    /// Cancellation while queued returns without invoking `operation`.
    public func withWrite(
        label: String,
        operation: @Sendable () async -> Void
    ) async {
        await withVoidOperation(access: .write, label: label, operation: operation)
    }

    public func withRead<Result: Sendable>(
        label: String,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withOperation(access: .read, label: label) { _ in
            try await operation()
        }
    }

    public func withWrite<Result: Sendable>(
        label: String,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withOperation(access: .write, label: label) { _ in
            try await operation()
        }
    }

    /// Acquires a read slot and exposes its lease for safe nested operations.
    public func withReadLease<Result: Sendable>(
        label: String,
        operation: @Sendable (Lease) async throws -> Result
    ) async throws -> Result {
        try await withOperation(access: .read, label: label, operation: operation)
    }

    /// Acquires a write slot and exposes its lease for safe nested operations.
    public func withWriteLease<Result: Sendable>(
        label: String,
        operation: @Sendable (Lease) async throws -> Result
    ) async throws -> Result {
        try await withOperation(access: .write, label: label, operation: operation)
    }

    /// Runs a nested read only when `lease` is still active and authorizes it.
    public func withRead<Result: Sendable>(
        holding lease: Lease,
        label _: String,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try retainNestedOperation(lease, requestedAccess: .read)
        defer { releaseNestedOperation(lease) }
        try Task.checkCancellation()
        return try await operation()
    }

    /// Runs a nested write only under an active write lease.
    public func withWrite<Result: Sendable>(
        holding lease: Lease,
        label _: String,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try retainNestedOperation(lease, requestedAccess: .write)
        defer { releaseNestedOperation(lease) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func withVoidOperation(
        access: Access,
        label: String,
        operation: @Sendable () async -> Void
    ) async {
        guard let lease = await acquire(access: access, label: label) else { return }
        defer { releaseRootOperation(lease) }
        guard !Task.isCancelled else { return }
        await operation()
    }

    private func withOperation<Result: Sendable>(
        access: Access,
        label: String,
        operation: @Sendable (Lease) async throws -> Result
    ) async throws -> Result {
        guard let lease = await acquire(access: access, label: label) else {
            if hasUnresolvedExternalMutation { throw LeaseError.externalInstallationPending }
            throw CancellationError()
        }
        defer { releaseRootOperation(lease) }
        try Task.checkCancellation()
        return try await operation(lease)
    }

    private func acquire(access: Access, label: String) async -> Lease? {
        guard !Task.isCancelled, !hasUnresolvedExternalMutation else { return nil }
        if canStartImmediately(access) {
            return start(access: access, label: label)
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters.append(Waiter(
                        id: waiterID,
                        access: access,
                        label: label,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
        drainWaitersIfPossible()
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

    private func start(access: Access, label: String) -> Lease {
        let operationID = UUID()
        switch access {
        case .read:
            activeReads += 1
        case .write:
            activeWrite = label
        }
        activeOperations[operationID] = ActiveOperation(access: access)
        return Lease(coordinatorID: coordinatorID, operationID: operationID, access: access)
    }

    private func releaseRootOperation(_ lease: Lease) {
        guard var active = activeOperations[lease.operationID] else { return }
        if active.nestedOperations > 0 {
            active.rootReleased = true
            activeOperations[lease.operationID] = active
            return
        }
        finishOperation(id: lease.operationID, access: active.access)
    }

    private func retainNestedOperation(_ lease: Lease, requestedAccess: Access) throws {
        try validate(lease, requestedAccess: requestedAccess)
        activeOperations[lease.operationID]?.nestedOperations += 1
    }

    private func releaseNestedOperation(_ lease: Lease) {
        guard var active = activeOperations[lease.operationID], active.nestedOperations > 0 else {
            return
        }
        active.nestedOperations -= 1
        if active.rootReleased, active.nestedOperations == 0 {
            finishOperation(id: lease.operationID, access: active.access)
        } else {
            activeOperations[lease.operationID] = active
        }
    }

    private func finishOperation(id: UUID, access: Access) {
        activeOperations.removeValue(forKey: id)
        switch access {
        case .read:
            activeReads -= 1
        case .write:
            activeWrite = nil
        }
        drainWaitersIfPossible()
    }

    private func validate(_ lease: Lease, requestedAccess: Access) throws {
        guard lease.coordinatorID == coordinatorID else { throw LeaseError.foreignCoordinator }
        guard let active = activeOperations[lease.operationID],
              active.access == lease.access,
              !active.rootReleased else {
            throw LeaseError.expired
        }
        if requestedAccess == .write, active.access != .write {
            throw LeaseError.insufficientAccess
        }
    }

    private func drainWaitersIfPossible() {
        guard activeReads == 0, activeWrite == nil, !waiters.isEmpty else { return }
        if hasUnresolvedExternalMutation {
            let blocked = waiters
            waiters.removeAll()
            for waiter in blocked { waiter.continuation.resume(returning: nil) }
            return
        }

        if waiters[0].access == .write {
            let waiter = waiters.removeFirst()
            let lease = start(access: waiter.access, label: waiter.label)
            waiter.continuation.resume(returning: lease)
            return
        }

        while !waiters.isEmpty, waiters[0].access == .read {
            let waiter = waiters.removeFirst()
            let lease = start(access: waiter.access, label: waiter.label)
            waiter.continuation.resume(returning: lease)
        }
    }
}
