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

    func performWrite<Result: Sendable>(
        _ flow: Flow,
        operation: @MainActor @Sendable () async throws -> Result
    ) async rethrows -> Result {
        let requestID = UUID()
        requests.append((requestID, flow))
        if runningRequestID == nil { state = .waiting(flow) }
        defer { finish(requestID) }

        return try await operations.withWrite(label: flow.rawValue) { @MainActor in
            self.runningRequestID = requestID
            self.state = .running(flow)
            return try await operation()
        }
    }

    private func finish(_ requestID: UUID) {
        requests.removeAll { $0.id == requestID }
        guard runningRequestID == requestID else { return }
        runningRequestID = nil
        state = requests.first.map { .waiting($0.flow) } ?? .idle
    }
}
