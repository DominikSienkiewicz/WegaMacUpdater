import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LT-01 — undo retention regression")
struct UndoableUpdateRetentionRegressionTests {
    private struct Fixture {
        let root: URL
        let store: UpdateOperationStore
        let snapshotURL: URL
        let committedAt: Date
    }

    @Test("Expired snapshots are not offered before the retention sweep runs")
    func expiredSnapshotIsNotUndoableWithoutPruning() throws {
        let fixture = try committedSnapshot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let afterRetention = fixture.committedAt
            .addingTimeInterval(UpdateOperationStore.retentionInterval + 1)

        #expect(FileManager.default.fileExists(atPath: fixture.snapshotURL.path))
        #expect(fixture.store.undoableUpdates(now: afterRetention).isEmpty)
    }

    @Test("A snapshot remains undoable at the exact retention boundary")
    func snapshotIsUndoableAtExactExpiry() throws {
        let fixture = try committedSnapshot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expiresAt = fixture.committedAt
            .addingTimeInterval(UpdateOperationStore.retentionInterval)

        #expect(fixture.store.undoableUpdates(now: expiresAt).map(\.token) == ["figma"])
    }

    private func committedSnapshot() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-01-expired-undo-\(UUID().uuidString)", isDirectory: true)
        let store = UpdateOperationStore(rootDirectory: root)
        let committedAt = Date(timeIntervalSince1970: 2_000_000)
        let appURL = root.appendingPathComponent("fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)

        let session = store.begin(trigger: .manual, now: committedAt)
        session.recordPlanned(tokens: ["figma"], appPaths: ["figma": appURL], now: committedAt)

        let snapshotName = "figma.app"
        try FileManager.default.createDirectory(
            at: session.snapshotsDirectory,
            withIntermediateDirectories: true
        )
        let snapshotURL = store.snapshotURL(operationID: session.operation.id, name: snapshotName)
        try FileManager.default.copyItem(at: appURL, to: snapshotURL)
        session.recordSnapshotted(token: "figma", snapshotName: snapshotName, now: committedAt)
        session.recordInstalling(now: committedAt)
        session.recordVerdict(token: "figma", verdict: .healthy, now: committedAt)

        return Fixture(
            root: root,
            store: store,
            snapshotURL: snapshotURL,
            committedAt: committedAt
        )
    }
}
