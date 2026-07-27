import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-01 — the durable, journaled update operation: phases survive the process, every
/// operation owns a unique directory, committed snapshots live for the retention window
/// (never deleted at validation time), and an interrupted operation is recognizable —
/// and settleable — from its journal alone.
@Suite("LT-01 — UpdateOperationJournal")
struct UpdateOperationJournalTests {

    // MARK: harness

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-01-journal-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeApp(at url: URL, bundleID: String = "com.example.figma", version: String = "1.0") throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// A live session one phase short of the brew run: planned + snapshotted, with a real
    /// (tiny) "app" cloned by hand — `clonefile` is covered by the guard's integration.
    private func makeOperation(
        store: UpdateOperationStore,
        tokens: [String] = ["figma"],
        version: String = "1.0",
        now: Date = Date()
    ) throws -> (UpdateOperationSession, [String: URL]) {
        let appPaths = try Dictionary(uniqueKeysWithValues: tokens.map { token in
            let appURL = store.operationDirectory(id: UUID())
                .deletingLastPathComponent()
                .appendingPathComponent("fixtures-\(UUID().uuidString)/\(token).app", isDirectory: true)
            try makeApp(at: appURL, version: version)
            return (token, appURL)
        })
        let session = store.begin(trigger: .manual, now: now)
        session.recordPlanned(tokens: tokens, appPaths: appPaths, now: now)
        for token in tokens {
            let name = "\(token).app"
            try FileManager.default.createDirectory(
                at: session.snapshotsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: appPaths[token]!,
                to: store.snapshotURL(operationID: session.operation.id, name: name)
            )
            session.recordSnapshotted(token: token, snapshotName: name, now: now)
        }
        return (session, appPaths)
    }

    // MARK: phases

    /// The card's core promise: `planned → snapshotted → installing → verified → committed`
    /// is on disk, in order, after a healthy run — readable by a process that never saw
    /// the live one.
    @Test func healthyRunJournalsEveryPhaseToDisk() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        let (session, _) = try makeOperation(store: store, now: t0)
        session.recordInstalling(now: t0.addingTimeInterval(1))
        session.recordVerdict(token: "figma", verdict: .healthy, now: t0.addingTimeInterval(2))

        let reloaded = try #require(store.operations().first)
        let item = try #require(reloaded.items.first)
        #expect(item.phase == .committed)
        #expect(item.history.map(\.phase) == [.planned, .snapshotted, .installing, .verified, .committed],
                "LT-01: every phase the card names must be journaled, in order")
        #expect(reloaded.isFinished)
    }

    @Test func rolledBackIsTerminalAndJournaled() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let (session, _) = try makeOperation(store: store)

        session.recordInstalling()
        session.recordVerdict(token: "figma", verdict: .publisherChangedAndRolledBack(old: "A", new: "B"))

        let item = try #require(store.operations().first?.items.first)
        #expect(item.phase == .rolledBack)
        #expect(item.phase.isTerminal)
        #expect(!item.history.map(\.phase).contains(.verified),
                "a rejected build never passed the canary — `verified` must not appear")
    }

    /// A failed rollback is the case that must never be silently settled: the item stays
    /// non-terminal so recovery probes it at the next launch instead of giving up on it.
    @Test func rollbackFailedStaysNonTerminalForRecovery() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let (session, _) = try makeOperation(store: store)

        session.recordInstalling()
        session.recordVerdict(token: "figma", verdict: .rollbackFailed)

        let operation = try #require(store.operations().first)
        #expect(operation.items.first?.phase == .installing)
        #expect(!operation.isFinished,
                "an item whose restore failed is unfinished business for the next launch")
    }

    // MARK: unique directories

    @Test func everyOperationGetsItsOwnUniqueDirectory() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)

        let first = store.begin(trigger: .manual)
        let second = store.begin(trigger: .background)

        #expect(first.operation.id != second.operation.id)
        #expect(store.snapshotsDirectory(operationID: first.operation.id)
            != store.snapshotsDirectory(operationID: second.operation.id))
        #expect(store.operations().count == 2)
    }

    // MARK: retention

    /// The pre-LT-01 behavior this replaces: a healthy upgrade deleted its snapshot at
    /// validation time. Now the committed clone survives, listed for a manual undo until
    /// the retention window closes.
    @Test func committedSnapshotIsUndoableWithinRetention() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let (session, _) = try makeOperation(store: store, now: t0)
        session.recordInstalling(now: t0)
        session.recordVerdict(token: "figma", verdict: .healthy, now: t0)

        let undoable = store.undoableUpdates(now: t0.addingTimeInterval(3600))
        #expect(undoable.map(\.token) == ["figma"])
        #expect(undoable.first?.restoredVersion == "1.0")
        #expect(undoable.first?.expiresAt == t0.addingTimeInterval(UpdateOperationStore.retentionInterval))
    }

    @Test func retentionSweepExpiresOldSnapshotsAndKeepsFreshOnes() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let ancient = Date(timeIntervalSince1970: 1_000_000)
        let now = ancient.addingTimeInterval(UpdateOperationStore.retentionInterval + 3600)

        let (oldSession, _) = try makeOperation(store: store, tokens: ["oldcask"], now: ancient)
        oldSession.recordInstalling(now: ancient)
        oldSession.recordVerdict(token: "oldcask", verdict: .healthy, now: ancient)
        let (freshSession, _) = try makeOperation(store: store, tokens: ["newcask"], now: now)
        freshSession.recordInstalling(now: now)
        freshSession.recordVerdict(token: "newcask", verdict: .healthy, now: now)

        let removed = store.pruneExpired(now: now)

        #expect(removed == 1)
        #expect(store.undoableUpdates(now: now).map(\.token) == ["newcask"])
        #expect(store.operations().map { $0.items.map(\.token) } == [["newcask"]],
                "a fully expired operation directory is removed, not just emptied")
    }

    /// Recovery's work is never the sweeper's: an operation with a non-terminal item must
    /// survive `pruneExpired` untouched, or the evidence of an interrupted upgrade would
    /// be deleted before anyone read it.
    @Test func retentionSweepNeverTouchesUnfinishedOperations() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let ancient = Date(timeIntervalSince1970: 1_000_000)
        let (session, _) = try makeOperation(store: store, now: ancient)
        session.recordInstalling(now: ancient)
        // Crash: no verdict ever recorded.

        let removed = store.pruneExpired(
            now: ancient.addingTimeInterval(UpdateOperationStore.retentionInterval * 4))

        #expect(removed == 0)
        #expect(store.operations().count == 1)
        let item = try #require(store.operations().first?.items.first)
        #expect(item.phase == .installing, "the interrupted item is still there to recover")
    }

    // MARK: manual undo

    @Test func markUndoneByUserSettlesTheItemAndClosesTheUndo() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let (session, _) = try makeOperation(store: store)
        session.recordInstalling()
        session.recordVerdict(token: "figma", verdict: .healthy)
        let operationID = session.operation.id

        #expect(store.undoableUpdates().map(\.token) == ["figma"])
        store.markUndoneByUser(operationID: operationID, token: "figma")

        let item = try #require(store.operationAndItem(operationID: operationID, token: "figma")?.1)
        #expect(item.phase == .rolledBack)
        #expect(item.rolledBackByUser,
                "a user-requested undo reads differently from a canary rollback in the journal")
        #expect(store.undoableUpdates().isEmpty)
    }

    // MARK: recovery plan

    @Test func recoveryActionPerPhase() {
        #expect(UpdateOperationRecoveryPlan.action(for: .planned) == .abortWithoutMutation)
        #expect(UpdateOperationRecoveryPlan.action(for: .snapshotted) == .abortWithoutMutation)
        #expect(UpdateOperationRecoveryPlan.action(for: .installing) == .probeInstalledApp)
        #expect(UpdateOperationRecoveryPlan.action(for: .verified) == .commitVerified)
        for phase: UpdateOperationPhase in [.committed, .rolledBack, .aborted] {
            #expect(UpdateOperationRecoveryPlan.action(for: phase) == .settle)
        }
    }

    @Test func installingProbeReadsTheDiskHonestly() {
        #expect(UpdateOperationRecoveryPlan.installingProbe(
            appExists: false, installedVersion: nil, preUpgradeVersion: "1.0") == .appMissing,
            "no app at the recorded path: the swap died mid-way")
        #expect(UpdateOperationRecoveryPlan.installingProbe(
            appExists: true, installedVersion: "1.0", preUpgradeVersion: "1.0") == .untouched,
            "same version on disk: brew never finished — nothing to roll back")
        #expect(UpdateOperationRecoveryPlan.installingProbe(
            appExists: true, installedVersion: "2.0", preUpgradeVersion: "1.0") == .mutated,
            "a new version is on disk: the upgrade landed unvalidated — run the canary")
        #expect(UpdateOperationRecoveryPlan.installingProbe(
            appExists: true, installedVersion: nil, preUpgradeVersion: "1.0") == .mutated,
            "an unreadable version cannot prove the disk untouched — probe as mutated")
    }

    /// The whole loop the card asks a regression test to drive: an operation "crashed"
    /// between phases is found by a fresh store instance, settled through the resumed
    /// session, and the settlement is itself journaled.
    @Test func resumedSessionSettlesAnInterruptedOperation() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let (session, _) = try makeOperation(store: store)
        let operationID = session.operation.id
        // "Crash" after snapshotted: brew never ran. A fresh store reads the journal.
        let recovered = try #require(UpdateOperationStore(rootDirectory: root).resumeSession(operationID: operationID))
        let item = try #require(recovered.operation.items.first)
        #expect(UpdateOperationRecoveryPlan.action(for: item.phase) == .abortWithoutMutation)

        recovered.markAborted(token: "figma")

        let settled = try #require(UpdateOperationStore(rootDirectory: root).operations().first)
        #expect(settled.items.first?.phase == .aborted)
        #expect(settled.isFinished)
    }

    /// One recovery attempt per item: an unrestorable failure must not re-run — and
    /// re-notify — on every launch for the rest of the app's life.
    @Test func recoveryAttemptsAreCounted() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let (session, _) = try makeOperation(store: store)
        session.recordInstalling()

        let resumed = try #require(store.resumeSession(operationID: session.operation.id))
        resumed.noteRecoveryAttempt(token: "figma")

        let item = try #require(store.operations().first?.items.first)
        #expect(item.recoveryAttempts == 1)
    }

    // MARK: snapshot name sanitization

    /// The journal name feeds a path a root helper may restore through — a token must
    /// never become a traversal.
    @Test func snapshotNamesCannotEscapeTheOperationDirectory() {
        #expect(UpdateOperationSession.snapshotDirectoryName(for: "../../etc/evil") == "..-..-etc-evil.app",
                "slashes become dashes; what remains is one inert filename, not a traversal")
        #expect(UpdateOperationSession.snapshotDirectoryName(for: "figma") == "figma.app")
        #expect(UpdateOperationSession.snapshotDirectoryName(for: "") == "snapshot.app")
        #expect(UpdateOperationSession.snapshotDirectoryName(for: "..") == "snapshot.app")
        for name in ["../../etc/evil", "a/b", "x\\y", "..", "."].map(UpdateOperationSession.snapshotDirectoryName) {
            #expect(!name.contains("/"), "\(name) must stay a single path component")
            #expect(name != "." && name != "..", "\(name) must not be a special directory entry")
        }
    }
}
