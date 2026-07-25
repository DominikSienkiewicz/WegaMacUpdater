import Foundation
import MacUpdaterCore

/// UI-facing state machine for every operation that can mutate Homebrew or an app bundle.
/// The underlying read/write gate is shared with background work and non-upgrade flows.
@MainActor
final class UpgradeCoordinator: ObservableObject {
    static let shared = UpgradeCoordinator()

    enum Flow: String, Equatable, Sendable {
        case brewMetadata = "brew update"
        case foregroundUpgrade = "foreground upgrade"
        case backgroundUpgrade = "background upgrade"
        case manualInstall = "manual install"
        case migration
        case cleanup
        case uninstall
        case duplicateRemoval = "duplicate removal"
        case selfUpdate = "self-update"
    }

    enum State: Equatable {
        case idle
        case waiting(Flow)
        case running(Flow)
    }

    @Published private(set) var state: State = .idle

    private let operations: OperationCoordinator
    private var requests: [(id: UUID, flow: Flow)] = []
    private var runningRequestID: UUID?

    init(operations: OperationCoordinator = .shared) {
        self.operations = operations
    }

    func performWrite(
        _ flow: Flow,
        operation: @MainActor @Sendable () async -> Void
    ) async {
        let requestID = begin(flow)
        defer { finish(requestID) }

        await operations.withWrite(label: flow.rawValue) { @MainActor in
            self.markRunning(requestID, flow: flow)
            await operation()
        }
    }

    func performWrite<Result: Sendable>(
        _ flow: Flow,
        operation: @MainActor @Sendable () async throws -> Result
    ) async throws -> Result {
        let requestID = begin(flow)
        defer { finish(requestID) }

        return try await operations.withWrite(label: flow.rawValue) { @MainActor in
            self.markRunning(requestID, flow: flow)
            return try await operation()
        }
    }

    func performWriteLease<Result: Sendable>(
        _ flow: Flow,
        operation: @MainActor @Sendable (OperationCoordinator.Lease) async throws -> Result
    ) async throws -> Result {
        let requestID = begin(flow)
        defer { finish(requestID) }

        return try await operations.withWriteLease(label: flow.rawValue) { @MainActor lease in
            self.markRunning(requestID, flow: flow)
            return try await operation(lease)
        }
    }

    private func begin(_ flow: Flow) -> UUID {
        let requestID = UUID()
        requests.append((requestID, flow))
        if runningRequestID == nil { state = .waiting(flow) }
        return requestID
    }

    private func markRunning(_ requestID: UUID, flow: Flow) {
        runningRequestID = requestID
        state = .running(flow)
    }

    private func finish(_ requestID: UUID) {
        requests.removeAll { $0.id == requestID }
        guard runningRequestID == requestID else { return }
        runningRequestID = nil
        state = requests.first.map { .waiting($0.flow) } ?? .idle
    }
}
