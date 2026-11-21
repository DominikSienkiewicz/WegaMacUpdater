import Foundation
import Testing
@testable import MacUpdaterCore
// SEC-10: SudoLocalTransactionalWriter now lives in WegaHelperKit (internal type).
@testable import WegaHelperKit

@Suite("Transactional sudo_local writer")
struct SudoLocalTransactionalWriterTests {
    @Test func successfulWriteBacksUpAtomicallyWritesAndVerifies() throws {
        let target = URL(fileURLWithPath: "/etc/pam.d/sudo_local")
        let backup = URL(fileURLWithPath: "/etc/pam.d/.sudo_local.wega-backup")
        let original = Data("auth required pam_opendirectory.so\n".utf8)
        let expected = Data("auth sufficient pam_tid.so\n".utf8)
        let fileSystem = RecordingSudoLocalFileSystem(files: [target: original])
        let writer = SudoLocalTransactionalWriter(
            fileSystem: fileSystem,
            makeBackupURL: { _ in backup }
        )

        try writer.writeAtomically(expected, to: target)

        #expect(fileSystem.files[target] == expected)
        #expect(fileSystem.files[backup] == nil)
        #expect(fileSystem.events == [
            "attributes sudo_local",
            "copy sudo_local .sudo_local.wega-backup",
            "write sudo_local",
            "secure sudo_local",
            "read sudo_local",
            "remove .sudo_local.wega-backup"
        ])
    }

    @Test func failedReadbackRollsBackTheOriginalBytes() throws {
        let target = URL(fileURLWithPath: "/etc/pam.d/sudo_local")
        let backup = URL(fileURLWithPath: "/etc/pam.d/.sudo_local.wega-backup")
        let original = Data("auth required pam_opendirectory.so\n".utf8)
        let expected = Data("auth sufficient pam_tid.so\n".utf8)
        let fileSystem = RecordingSudoLocalFileSystem(files: [target: original])
        fileSystem.corruptFirstTargetRead = true
        let writer = SudoLocalTransactionalWriter(
            fileSystem: fileSystem,
            makeBackupURL: { _ in backup }
        )

        #expect(throws: SudoLocalTransactionalWriter.WriteError.verificationFailed) {
            try writer.writeAtomically(expected, to: target)
        }
        #expect(fileSystem.files[target] == original)
        #expect(fileSystem.files[backup] == nil)
        let firstWrite = try #require(fileSystem.events.firstIndex(of: "write sudo_local"))
        let failedReadback = try #require(fileSystem.events.firstIndex(of: "read sudo_local"))
        let rollbackWrite = try #require(fileSystem.events.lastIndex(of: "write sudo_local"))
        #expect(firstWrite < failedReadback)
        #expect(failedReadback < rollbackWrite)
    }

    @Test func failedRollbackPreservesBackupForManualRecovery() throws {
        let target = URL(fileURLWithPath: "/etc/pam.d/sudo_local")
        let backup = URL(fileURLWithPath: "/etc/pam.d/.sudo_local.wega-backup")
        let original = Data("auth required pam_opendirectory.so\n".utf8)
        let expected = Data("auth sufficient pam_tid.so\n".utf8)
        let fileSystem = RecordingSudoLocalFileSystem(files: [target: original])
        fileSystem.corruptFirstTargetRead = true
        fileSystem.failRollbackWrite = true
        let writer = SudoLocalTransactionalWriter(
            fileSystem: fileSystem,
            makeBackupURL: { _ in backup }
        )

        #expect(throws: SudoLocalTransactionalWriter.WriteError.rollbackFailed(backupPath: backup.path)) {
            try writer.writeAtomically(expected, to: target)
        }
        #expect(fileSystem.files[backup] == original)
    }

    /// With no previous file there is no backup to name: the new, unverified file could not be
    /// removed, and the error says so instead of pointing at a copy that does not exist.
    @Test func aFailedRollbackWithoutAPreviousFileNamesNoBackup() throws {
        let target = URL(fileURLWithPath: "/etc/pam.d/sudo_local")
        let backup = URL(fileURLWithPath: "/etc/pam.d/.sudo_local.wega-backup")
        let fileSystem = RecordingSudoLocalFileSystem(files: [:])
        fileSystem.corruptFirstTargetRead = true
        fileSystem.failRemove = true
        let writer = SudoLocalTransactionalWriter(fileSystem: fileSystem, makeBackupURL: { _ in backup })

        #expect(throws: SudoLocalTransactionalWriter.WriteError.rollbackFailed(backupPath: nil)) {
            try writer.writeAtomically(Data("auth sufficient pam_tid.so\n".utf8), to: target)
        }
        #expect(fileSystem.files[backup] == nil)
    }

    /// The live backup name sits in the policy directory under the helper's own prefix, so the app
    /// accepts the path the enable reply carries for −21.
    @Test func theLiveBackupNameIsInThePolicyDirectoryUnderTheHelpersPrefix() {
        let target = URL(fileURLWithPath: "/private/etc/pam.d/sudo_local")
        let backup = SudoLocalTransactionalWriter.backupURL(for: target)
        #expect(backup.deletingLastPathComponent() == target.deletingLastPathComponent())
        #expect(backup.lastPathComponent.hasPrefix(TouchIDSudoDisabler.swapNamePrefix + "backup-"))
        #expect(backup != SudoLocalTransactionalWriter.backupURL(for: target), "a fresh name per write")
    }
}

private final class RecordingSudoLocalFileSystem: SudoLocalFileManaging {
    var files: [URL: Data]
    var events: [String] = []
    var corruptFirstTargetRead = false
    var failRollbackWrite = false
    var failRemove = false
    private var didCorruptTargetRead = false
    private var targetWriteCount = 0

    init(files: [URL: Data]) {
        self.files = files
    }

    func fileExists(at url: URL) -> Bool {
        files[url] != nil
    }

    func readData(at url: URL) throws -> Data {
        events.append("read \(url.lastPathComponent)")
        guard let data = files[url] else { throw StubFileError.missing }
        if corruptFirstTargetRead,
           url.lastPathComponent == "sudo_local",
           !didCorruptTargetRead {
            didCorruptTargetRead = true
            return Data("corrupt".utf8)
        }
        return data
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        events.append("attributes \(url.lastPathComponent)")
        guard files[url] != nil else { throw StubFileError.missing }
        return [.posixPermissions: NSNumber(value: 0o640)]
    }

    func copyItem(at source: URL, to destination: URL) throws {
        events.append("copy \(source.lastPathComponent) \(destination.lastPathComponent)")
        guard let data = files[source] else { throw StubFileError.missing }
        files[destination] = data
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        events.append("write \(url.lastPathComponent)")
        if url.lastPathComponent == "sudo_local" {
            targetWriteCount += 1
            if failRollbackWrite && targetWriteCount > 1 {
                throw StubFileError.writeFailed
            }
        }
        files[url] = data
    }

    func secureRootOwnedFile(at url: URL) throws {
        events.append("secure \(url.lastPathComponent)")
    }

    func restoreAttributes(_ attributes: [FileAttributeKey: Any], at url: URL) throws {
        events.append("restore-attributes \(url.lastPathComponent)")
    }

    func removeItem(at url: URL) throws {
        events.append("remove \(url.lastPathComponent)")
        if failRemove { throw StubFileError.writeFailed }
        files[url] = nil
    }

    private enum StubFileError: Error {
        case missing
        case writeFailed
    }
}
