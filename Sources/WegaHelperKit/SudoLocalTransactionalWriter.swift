import Foundation

protocol SudoLocalFileManaging {
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func attributes(at url: URL) throws -> [FileAttributeKey: Any]
    func copyItem(at source: URL, to destination: URL) throws
    func writeAtomically(_ data: Data, to url: URL) throws
    func secureRootOwnedFile(at url: URL) throws
    func restoreAttributes(_ attributes: [FileAttributeKey: Any], at url: URL) throws
    func removeItem(at url: URL) throws
}

struct SudoLocalTransactionalWriter {
    enum WriteError: Error, Equatable, LocalizedError {
        case verificationFailed
        case rollbackFailed

        var errorDescription: String? {
            switch self {
            case .verificationFailed:
                return "Odczyt kontrolny sudo_local nie zgadza się z zapisanymi danymi."
            case .rollbackFailed:
                return "Nie udało się przywrócić kopii sudo_local po błędzie zapisu."
            }
        }
    }

    private let fileSystem: SudoLocalFileManaging
    private let makeBackupURL: (URL) -> URL

    init(
        fileSystem: SudoLocalFileManaging = SystemSudoLocalFileManager(),
        makeBackupURL: @escaping (URL) -> URL = { target in
            target.deletingLastPathComponent().appendingPathComponent(
                ".sudo_local.wega-backup-\(UUID().uuidString)"
            )
        }
    ) {
        self.fileSystem = fileSystem
        self.makeBackupURL = makeBackupURL
    }

    func writeAtomically(_ expected: Data, to target: URL) throws {
        let targetExisted = fileSystem.fileExists(at: target)
        let originalAttributes = targetExisted ? try fileSystem.attributes(at: target) : [:]
        let backup = makeBackupURL(target)
        var backupCreated = false
        var shouldRemoveBackup = false

        if targetExisted {
            try fileSystem.copyItem(at: target, to: backup)
            backupCreated = true
        }
        defer {
            if backupCreated && shouldRemoveBackup {
                try? fileSystem.removeItem(at: backup)
            }
        }

        do {
            try fileSystem.writeAtomically(expected, to: target)
            try fileSystem.secureRootOwnedFile(at: target)
            try verifyReadback(expected, at: target)
            shouldRemoveBackup = true
        } catch {
            let originalError = error
            do {
                try rollback(
                    target: target,
                    targetExisted: targetExisted,
                    backup: backup,
                    originalAttributes: originalAttributes
                )
                shouldRemoveBackup = true
            } catch {
                // Preserve the backup for manual recovery when automatic rollback fails.
                throw WriteError.rollbackFailed
            }
            throw originalError
        }
    }

    private func verifyReadback(_ expected: Data, at target: URL) throws {
        guard try fileSystem.readData(at: target) == expected else {
            throw WriteError.verificationFailed
        }
    }

    private func rollback(
        target: URL,
        targetExisted: Bool,
        backup: URL,
        originalAttributes: [FileAttributeKey: Any]
    ) throws {
        if targetExisted {
            let original = try fileSystem.readData(at: backup)
            try fileSystem.writeAtomically(original, to: target)
            try fileSystem.restoreAttributes(originalAttributes, at: target)
            guard try fileSystem.readData(at: target) == original else {
                throw WriteError.rollbackFailed
            }
        } else if fileSystem.fileExists(at: target) {
            try fileSystem.removeItem(at: target)
        }
    }
}

private struct SystemSudoLocalFileManager: SudoLocalFileManaging {
    private let fileManager = FileManager.default

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try fileManager.attributesOfItem(atPath: url.path)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func secureRootOwnedFile(at url: URL) throws {
        try fileManager.setAttributes(
            [
                .posixPermissions: NSNumber(value: 0o644),
                .ownerAccountID: NSNumber(value: 0),
                .groupOwnerAccountID: NSNumber(value: 0)
            ],
            ofItemAtPath: url.path
        )
    }

    func restoreAttributes(_ attributes: [FileAttributeKey: Any], at url: URL) throws {
        let keys: Set<FileAttributeKey> = [
            .posixPermissions, .ownerAccountID, .groupOwnerAccountID
        ]
        try fileManager.setAttributes(
            attributes.filter { keys.contains($0.key) },
            ofItemAtPath: url.path
        )
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}
