import Darwin
import Foundation

public struct PackageInstallationStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case running, succeeded, failed, notStarted, unknown

        public var isTerminal: Bool { self == .succeeded || self == .failed || self == .notStarted }
    }

    public let operationID: UUID
    public var phase: Phase
    public var message: String?

    public init(operationID: UUID, phase: Phase, message: String? = nil) {
        self.operationID = operationID
        self.phase = phase
        self.message = message
    }
}

/// One durable registry for every XPC connection. A missing request is tombstoned before
/// reporting "not started", so a delayed delivery cannot start after the client releases its gate.
public final class PackageInstallationRegistry: @unchecked Sendable {
    public enum Failure: Error, LocalizedError {
        case anotherInstallationUnresolved
        case missingOperation
        case bootIdentityUnavailable

        public var errorDescription: String? {
            switch self {
            case .anotherInstallationUnresolved: return "Poprzednia instalacja nadal działa lub jej wynik jest nieznany."
            case .missingOperation: return "Nie znaleziono rozpoczętej instalacji."
            case .bootIdentityUnavailable: return "Nie można ustalić sesji uruchomienia systemu."
            }
        }
    }

    private struct Record: Codable {
        var status: PackageInstallationStatus
        let bootID: String
    }

    private let lock = NSLock()
    private let fileURL: URL
    private let bootID: String
    private var records: [String: Record]

    public init(fileURL: URL, bootID: String) throws {
        self.fileURL = fileURL
        self.bootID = bootID
        if FileManager.default.fileExists(atPath: fileURL.path) {
            records = try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: fileURL))
        } else {
            records = [:]
        }
        for key in Array(records.keys) {
            guard var record = records[key], !record.status.phase.isTerminal else { continue }
            record.status.phase = record.bootID == bootID ? .unknown : .failed
            record.status.message = record.bootID == bootID
                ? "Helper został uruchomiony ponownie. Stan wcześniejszego instalatora jest nieznany."
                : "System został uruchomiony ponownie przed potwierdzeniem instalacji. Sprawdź zainstalowaną aplikację."
            records[key] = record
        }
    }

    public static func currentBootID() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            throw Failure.bootIdentityUnavailable
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            throw Failure.bootIdentityUnavailable
        }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `true` gives exactly one caller permission to launch. Retries return the existing status.
    public func begin(_ id: UUID) throws -> Bool {
        try lock.withLock {
            guard records[id.uuidString] == nil else { return false }
            guard !records.values.contains(where: { !$0.status.phase.isTerminal }) else {
                throw Failure.anotherInstallationUnresolved
            }
            try save(Record(status: .init(operationID: id, phase: .running), bootID: bootID))
            return true
        }
    }

    public func status(_ id: UUID) throws -> PackageInstallationStatus {
        try lock.withLock {
            if let record = records[id.uuidString] { return record.status }
            let status = PackageInstallationStatus(operationID: id, phase: .notStarted, message: "Instalacja nie została rozpoczęta. Możesz ponowić aktualizację.")
            try save(Record(status: status, bootID: bootID))
            return status
        }
    }

    public func finish(_ id: UUID, succeeded: Bool, message: String?) throws {
        try lock.withLock {
            guard let record = records[id.uuidString], record.status.phase == .running else {
                throw Failure.missingOperation
            }
            let status = PackageInstallationStatus(operationID: id, phase: succeeded ? .succeeded : .failed, message: message)
            try save(Record(status: status, bootID: bootID))
        }
    }

    public func requireNoUnresolvedInstallation() throws {
        try lock.withLock {
            if records.values.contains(where: { !$0.status.phase.isTerminal }) {
                throw Failure.anotherInstallationUnresolved
            }
        }
    }

    private func save(_ record: Record) throws {
        var updated = records
        updated[record.status.operationID.uuidString] = record
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        records = updated
    }
}
