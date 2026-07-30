import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LT-01 — undo retention regression")
struct UndoableUpdateRetentionRegressionTests {
    @Test("Expired snapshots are not offered before the retention sweep runs")
    func expiredSnapshotIsNotUndoableWithoutPruning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-01-expired-undo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

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

        let afterRetention = committedAt.addingTimeInterval(UpdateOperationStore.retentionInterval + 1)

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(store.undoableUpdates(now: afterRetention).isEmpty)
    }
}
