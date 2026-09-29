import Foundation
import WegaHelperKit

/// Connection deadlines bound observation, never the lifetime of the privileged installer.
public struct HelperPackageInstallation: Sendable {
    public enum Failure: Error, LocalizedError {
        case outcomeUnknown(operationID: UUID)
        case rejected(String)

        public var errorDescription: String? {
            switch self {
            case .outcomeUnknown(let id):
                return "Nie potwierdzono zakończenia instalacji \(id.uuidString). Sprawdź jej stan w Ustawieniach Wega."
            case .rejected(let message): return message
            }
        }
    }

    private let store: PendingHelperInstallationStore
    private let handshake: @Sendable () async throws -> Void
    private let begin: @Sendable (UUID, String) async throws -> PackageInstallationStatus
    private let status: @Sendable (UUID) async throws -> PackageInstallationStatus

    public init(
        store: PendingHelperInstallationStore = .shared,
        handshake: @escaping @Sendable () async throws -> Void,
        begin: @escaping @Sendable (UUID, String) async throws -> PackageInstallationStatus,
        status: @escaping @Sendable (UUID) async throws -> PackageInstallationStatus
    ) {
        self.store = store
        self.handshake = handshake
        self.begin = begin
        self.status = status
    }

    public func install(at path: String, version: String, timeout: Duration = .seconds(1800)) async throws {
        try await handshake()
        try Task.checkCancellation()
        let pending = PendingHelperInstallation(operationID: UUID(), version: version)
        try store.reserve(pending)
        WegaLog.info(.helper, "Żądanie instalacji \(pending.operationID), wersja \(version)")
        let result: PackageInstallationStatus
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var observed = try await begin(pending.operationID, path)
            while !observed.phase.isTerminal, observed.phase != .unknown, clock.now < deadline {
                try await Task.sleep(for: .seconds(2))
                observed = try await status(pending.operationID)
            }
            result = observed
        } catch {
            WegaLog.error(.helper, "Utracono potwierdzenie instalacji \(pending.operationID): \(error.localizedDescription)")
            throw Failure.outcomeUnknown(operationID: pending.operationID)
        }
        try settle(result, pending: pending)
    }

    /// Queries only: reconnecting must never submit the installer a second time.
    public func reconcile() async throws -> PendingHelperInstallation? {
        guard let pending = try store.load() else { return nil }
        let result: PackageInstallationStatus
        do {
            try await handshake()
            result = try await status(pending.operationID)
        } catch {
            WegaLog.error(.helper, "Nie można odczytać instalacji \(pending.operationID): \(error.localizedDescription)")
            throw Failure.outcomeUnknown(operationID: pending.operationID)
        }
        try settle(result, pending: pending)
        return pending
    }

    private func settle(_ result: PackageInstallationStatus, pending: PendingHelperInstallation) throws {
        guard result.operationID == pending.operationID, result.phase.isTerminal else {
            WegaLog.warning(.helper, "Instalacja \(pending.operationID): \(result.phase.rawValue) — \(result.message ?? "brak potwierdzenia zakończenia")")
            throw Failure.outcomeUnknown(operationID: pending.operationID)
        }
        try store.clear(matching: pending.operationID)
        WegaLog.info(.helper, "Potwierdzony wynik instalacji \(pending.operationID): \(result.phase.rawValue)")
        guard result.phase == .succeeded else {
            throw Failure.rejected(result.message ?? "Instalacja nie została potwierdzona jako udana.")
        }
    }
}
