import Foundation
import Testing
@testable import MacUpdaterCore

/// An upgrade that never replaced the bundle is not a success.
///
/// The Obsidian loop, observed 2026-08-17: `/opt/homebrew/Caskroom/obsidian/1.13.7` was
/// recorded on 2026-08-12, but `/Applications/Obsidian.app` still reported `1.13.6`. With its
/// own record already at 1.13.7, brew had nothing to do — `brew outdated --cask --greedy
/// obsidian` printed nothing and every `brew upgrade` exited 0 without touching the disk.
///
/// Wega then contradicted itself, because the two ends of a run read different sources:
/// the confirming rescan asks *brew* (`outdatedGreedy`), which said "fine", so the item was
/// journaled `verified → committed`; the next full scan reads the *bundle* (`Info.plist`), saw
/// 1.13.6 against a cask offering 1.13.7, and called it outdated again. The user upgraded, was
/// told it worked, and was told it was old again — twice over, on 2026-08-15 and 2026-08-17,
/// both with `preUpgradeVersion: 1.13.6`.
///
/// The snapshot is the pre-upgrade bundle, so the one source that a stale Caskroom cannot
/// fool is the version on disk compared against it. `.notUpgraded` is that reading, and it
/// must never reach `committed`.
@Suite("A cask upgrade that never replaced the bundle is not a success")
struct NoOpCaskUpgradeTests {

    // MARK: harness

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("no-op-upgrade-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeApp(at url: URL, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "md.obsidian",
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func makeOperation(
        store: UpdateOperationStore,
        token: String = "obsidian",
        version: String = "1.13.6"
    ) throws -> UpdateOperationSession {
        let appURL = store.operationDirectory(id: UUID())
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures-\(UUID().uuidString)/\(token).app", isDirectory: true)
        try makeApp(at: appURL, version: version)

        let session = store.begin(trigger: .manual)
        session.recordPlanned(tokens: [token], appPaths: [token: appURL])
        let name = "\(token).app"
        try FileManager.default.createDirectory(
            at: session.snapshotsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: appURL, to: store.snapshotURL(operationID: session.operation.id, name: name))
        session.recordSnapshotted(token: token, snapshotName: name)
        return session
    }

    // MARK: the regression

    /// Red before the fix: `CaskValidationVerdict` has no `.notUpgraded`, so a no-op run can
    /// only be reported as `.healthy` — and `recordVerdict` stamps `verified → committed` for
    /// that, which is the bogus "zaktualizowano" the user saw twice.
    @Test func anUpgradeThatNeverReplacedTheBundleIsNotCommitted() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let session = try makeOperation(store: store)

        session.recordInstalling()
        session.recordVerdict(token: "obsidian", verdict: .notUpgraded)

        let item = try #require(store.operations().first?.items.first)
        #expect(item.phase != .committed,
                "a run that changed nothing on disk must not be recorded as an applied update")
        #expect(item.history.map(\.phase).contains(.verified) == false,
                "no canary passed here — the canary would have inspected the *old* bundle")
        #expect(item.phase == .aborted,
                "nothing was mutated, so the item is settled as aborted and its snapshot is redundant")
    }

    /// The decision itself, as a pure reading: the snapshot holds the pre-upgrade build, so an
    /// equal version on disk means brew did nothing.
    @Test func matchingVersionsMeanTheBundleWasNeverReplaced() {
        #expect(UpdateOperationRecoveryPlan.bundleWasReplaced(
            installedVersion: "1.13.6", snapshotVersion: "1.13.6") == false,
            "the exact Obsidian case: brew exits 0, the disk is untouched")
        #expect(UpdateOperationRecoveryPlan.bundleWasReplaced(
            installedVersion: "1.13.7", snapshotVersion: "1.13.6"),
            "a moved version is a real upgrade")
    }

    /// An unreadable version is not evidence of a no-op. Treating it as one would turn every
    /// bundle Wega cannot parse into a failed upgrade.
    @Test func anUnreadableVersionIsNotTreatedAsANoOp() {
        #expect(UpdateOperationRecoveryPlan.bundleWasReplaced(
            installedVersion: nil, snapshotVersion: "1.13.6"))
        #expect(UpdateOperationRecoveryPlan.bundleWasReplaced(
            installedVersion: "1.13.6", snapshotVersion: nil))
    }
}
