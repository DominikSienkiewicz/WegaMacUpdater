import Foundation

public struct PendingHelperInstallation: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let version: String

    public init(operationID: UUID, version: String) {
        self.operationID = operationID
        self.version = version
    }
}

/// This receipt is saved before sending XPC. Its existence blocks further mutations even
/// after a client restart or when a damaged receipt cannot be decoded.
public final class PendingHelperInstallationStore: @unchecked Sendable {
    public static let shared: PendingHelperInstallationStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return PendingHelperInstallationStore(fileURL: base.appendingPathComponent("WegaMacUpdater/pending-helper-installation.json"))
    }()

    public enum Failure: Error { case alreadyPending, identityMismatch }
    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }
    public var hasPending: Bool {
        do { return try fileURL.checkResourceIsReachable() }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return false }
        catch { return true }
    }

    public func load() throws -> PendingHelperInstallation? { try lock.withLock { try loadUnlocked() } }

    public func reserve(_ pending: PendingHelperInstallation) throws {
        try lock.withLock {
            guard !hasPending else { throw Failure.alreadyPending }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    public func clear(matching id: UUID) throws {
        try lock.withLock {
            guard let pending = try loadUnlocked() else { return }
            guard pending.operationID == id else { throw Failure.identityMismatch }
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func loadUnlocked() throws -> PendingHelperInstallation? {
        guard hasPending else { return nil }
        return try JSONDecoder().decode(PendingHelperInstallation.self, from: Data(contentsOf: fileURL))
    }
}
