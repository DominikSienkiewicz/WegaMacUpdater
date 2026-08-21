import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-01 follow-up — „Cofnij aktualizacje” offers one step back per app, never a stack of
/// them.
///
/// The regression: `undoableUpdates()` listed *every* retained snapshot, so an app updated
/// three times inside the seven-day window produced three rows with the same name and three
/// different „przywróci wersję …” subtitles. Only the newest of them is a step back from
/// what is installed; the older ones would jump the app over versions it is no longer
/// running, and every one of them shared the row's busy spinner because that keys on the
/// token.
@Suite("LT-01 — one undo row per app")
struct UndoOnlyLatestPerAppRegressionTests {

    @Test("An app updated three times offers only the step back from the installed version")
    func repeatedUpdatesCollapseToTheNewestSnapshot() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let day: TimeInterval = 24 * 60 * 60
        let t0 = Date(timeIntervalSince1970: 2_000_000)

        // chatgpt went 2.0 → 3.0 → 4.0 → 5.0 over three days; obsidian was updated once.
        try commitUpdate(store: store, root: root, token: "chatgpt", preUpgradeVersion: "2.0", at: t0)
        try commitUpdate(store: store, root: root, token: "chatgpt", preUpgradeVersion: "3.0", at: t0 + day)
        try commitUpdate(store: store, root: root, token: "chatgpt", preUpgradeVersion: "4.0", at: t0 + 2 * day)
        try commitUpdate(store: store, root: root, token: "obsidian", preUpgradeVersion: "1.13.6", at: t0 + day)

        let undoable = store.undoableUpdates(now: t0 + 3 * day)

        #expect(undoable.map(\.token) == ["chatgpt", "obsidian"],
                "one row per app, newest first — not one row per retained snapshot")
        #expect(undoable.first?.restoredVersion == "4.0",
                "the offered undo is the step back from what is installed, not a jump over 4.0 and 3.0")
    }

    /// Collapsing the list must not silently discard the older snapshots: after the newest
    /// undo is spent, the step before it is what „cofnij jeszcze raz” means, and it is still
    /// on disk until the retention sweep takes it.
    @Test("Undoing the newest step reveals the one before it")
    func theStepBeforeSurfacesAfterAnUndo() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let day: TimeInterval = 24 * 60 * 60
        let t0 = Date(timeIntervalSince1970: 2_000_000)

        try commitUpdate(store: store, root: root, token: "chatgpt", preUpgradeVersion: "3.0", at: t0)
        try commitUpdate(store: store, root: root, token: "chatgpt", preUpgradeVersion: "4.0", at: t0 + day)

        let newest = try #require(store.undoableUpdates(now: t0 + day).first)
        store.markUndoneByUser(operationID: newest.operationID, token: newest.token, now: t0 + day)

        let remaining = store.undoableUpdates(now: t0 + day)
        #expect(remaining.map(\.restoredVersion) == ["3.0"])
    }

    /// The pure half: whichever order the journals are read in, the surviving row per token
    /// is the newest one, and ties resolve deterministically instead of by dictionary order.
    @Test("Collapsing keeps the newest entry regardless of input order")
    func newestPerTokenIsOrderIndependent() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let old = makeUndoable(token: "chatgpt", restoredVersion: "3.0", updatedAt: t0)
        let new = makeUndoable(token: "chatgpt", restoredVersion: "4.0", updatedAt: t0 + 60)
        let other = makeUndoable(token: "obsidian", restoredVersion: "1.13.6", updatedAt: t0 + 30)

        for input in [[old, new, other], [new, other, old], [other, old, new]] {
            let collapsed = UndoableUpdate.newestPerToken(input)
            #expect(collapsed.map(\.token) == ["chatgpt", "obsidian"])
            #expect(collapsed.first?.restoredVersion == "4.0")
        }
    }

    // MARK: harness

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-01-latest-undo-\(UUID().uuidString)", isDirectory: true)
    }

    /// One committed update, journaled through the phases the real run walks.
    ///
    /// Every call gets its own fixture bundle even though a real app keeps one path across
    /// updates: `recordPlanned` reads the version through `Bundle(url:)`, whose per-URL cache
    /// would answer with the first version for every later "update" at the same path.
    private func commitUpdate(
        store: UpdateOperationStore,
        root: URL,
        token: String,
        preUpgradeVersion: String,
        at now: Date
    ) throws {
        let appURL = root
            .appendingPathComponent("fixtures-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(token).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.\(token)",
            "CFBundleShortVersionString": preUpgradeVersion,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let session = store.begin(trigger: .manual, now: now)
        session.recordPlanned(tokens: [token], appPaths: [token: appURL], now: now)
        let snapshotName = UpdateOperationSession.snapshotDirectoryName(for: token)
        try FileManager.default.createDirectory(
            at: session.snapshotsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: appURL,
            to: store.snapshotURL(operationID: session.operation.id, name: snapshotName)
        )
        session.recordSnapshotted(token: token, snapshotName: snapshotName, now: now)
        session.recordInstalling(now: now)
        session.recordVerdict(token: token, verdict: .healthy, now: now)
    }

    private func makeUndoable(token: String, restoredVersion: String, updatedAt: Date) -> UndoableUpdate {
        UndoableUpdate(
            operationID: UUID(),
            token: token,
            appPath: "/Applications/\(token).app",
            restoredVersion: restoredVersion,
            updatedAt: updatedAt,
            expiresAt: updatedAt.addingTimeInterval(UpdateOperationStore.retentionInterval)
        )
    }
}
