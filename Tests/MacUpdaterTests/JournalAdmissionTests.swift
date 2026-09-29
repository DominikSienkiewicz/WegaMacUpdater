import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("A durable journal admits a protected mutation")
struct JournalAdmissionTests {
    @Test(arguments: [UpdateOperationPhase.planned, .snapshotted, .installing])
    func aFailedPhaseWriteCannotAdmitTheInstaller(_ failingPhase: UpdateOperationPhase) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root, writeJournal: { data, url in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let operation = try decoder.decode(UpdateOperation.self, from: data)
            if operation.items.contains(where: { $0.phase == failingPhase }) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        let session = store.begin(trigger: .manual)
        session.recordPlanned(tokens: ["example"], appPaths: ["example": root.appendingPathComponent("Example.app")])
        session.recordSnapshotted(token: "example", snapshotName: "example.app")
        session.recordInstalling()
        #expect(throws: UpdateOperationPersistenceError.self) { try session.requirePersisted() }
    }

    @Test func failedInstallingLeavesTheLastDurablePhaseAndSnapshotRecoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root, writeJournal: { data, url in
            if String(decoding: data, as: UTF8.self).contains("\"installing\"") {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        })
        let session = store.begin(trigger: .background)
        session.recordPlanned(tokens: ["example"], appPaths: ["example": root.appendingPathComponent("Example.app")])
        try FileManager.default.createDirectory(at: session.snapshotsDirectory, withIntermediateDirectories: true)
        let snapshot = session.snapshotsDirectory.appendingPathComponent("example.app")
        try Data("snapshot".utf8).write(to: snapshot)
        session.recordSnapshotted(token: "example", snapshotName: "example.app")
        try session.requirePersisted()
        session.recordInstalling()
        #expect(throws: UpdateOperationPersistenceError.self) { try session.requirePersisted() }
        #expect(store.operations().first?.items.first?.phase == .snapshotted)
        _ = store.pruneExpired(now: Date.distantFuture)
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
    }

    @Test func theEmptyInitialJournalMustAlsoBeWritable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root, writeJournal: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let session = store.begin(trigger: .adoption)
        #expect(throws: UpdateOperationPersistenceError.self) { try session.requirePersisted() }
    }

    @Test func aConfirmedInstallingRecordSurvivesReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let session = store.begin(trigger: .manual)
        session.recordPlanned(tokens: ["example"], appPaths: ["example": root.appendingPathComponent("Example.app")])
        session.recordSnapshotted(token: "example", snapshotName: "example.app")
        session.recordInstalling()
        try session.requirePersisted()
        let reopened = try #require(store.resumeSession(operationID: session.operation.id))
        #expect(reopened.operation.hasDurablePhaseContract)
        #expect(reopened.operation.items.first?.phase == .installing)
    }

    @Test func failedCompletionWriteKeepsInstallingOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root, writeJournal: { data, url in
            if String(decoding: data, as: UTF8.self).contains("\"committed\"") { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let session = store.begin(trigger: .manual)
        session.recordPlanned(tokens: ["example"], appPaths: ["example": root.appendingPathComponent("Example.app")])
        session.recordSnapshotted(token: "example", snapshotName: "example.app")
        session.recordInstalling()
        try session.requirePersisted()
        session.recordVerdict(token: "example", verdict: .healthy)
        #expect(throws: UpdateOperationPersistenceError.self) { try session.requirePersisted() }
        #expect(store.operations().first?.items.first?.phase == .installing)
    }

    @Test func corruptJournalDoesNotAuthorizePruningItsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let session = store.begin(trigger: .manual)
        let directory = store.operationDirectory(id: session.operation.id)
        try Data("{broken".utf8).write(to: directory.appendingPathComponent("operation.json"))
        try FileManager.default.createDirectory(at: session.snapshotsDirectory, withIntermediateDirectories: true)
        _ = store.pruneExpired(now: Date.distantFuture)
        #expect(FileManager.default.fileExists(atPath: session.snapshotsDirectory.path))
    }
}
