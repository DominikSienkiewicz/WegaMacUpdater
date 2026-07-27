import Foundation
import Testing
@testable import MacUpdaterCore

/// QA-01d — regression lock for the SEC-02 guarantee that a publisher mismatch
/// **retains both the trusted baseline and the pre-upgrade snapshot**.
///
/// A silent publisher swap (cask/project takeover) is the moment the two things that
/// can *warn about* and *undo* it must survive:
///   • the trusted Team ID baseline in `TeamIDLedger` — so the mismatch keeps being
///     reported and the new publisher is never legalized; and
///   • the copy-on-write `BundleSnapshot` clone of the old app — so the previous
///     version can still be restored, even after the automatic rollback.
///
/// This suite pins that scenario at both the mechanism level (real `TeamIDLedger` /
/// `BundleSnapshot` behaviour) and the wiring level (the `.changed` branch of
/// `CaskRollbackGuard.verify`, which lives in the app target that this test bundle
/// cannot import, so it is read as source).
@Suite("QA-01d — publisher mismatch retains baseline and snapshot")
struct QA01DPublisherMismatchRetentionTests {

    // MARK: Baseline retention (Sources/MacUpdaterCore/TeamIDLedger.swift:58)

    /// A `.changed` audit is evidence to surface, never permission to overwrite the
    /// known-good Team ID. The baseline must keep pointing at the trusted publisher —
    /// on the mismatch itself, on every re-check, and even when the new signature is
    /// unreadable (which must not be allowed to erase it either).
    @Test func publisherMismatchNeverOverwritesTheTrustedBaseline() throws {
        let suiteName = "wega-qa01d-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ledger = TeamIDLedger(defaults: defaults)
        let bundleID = "cask:figma"

        #expect(ledger.record(bundleID: bundleID, teamID: "TRUSTED") == .firstSeen(teamID: "TRUSTED"))

        #expect(ledger.record(bundleID: bundleID, teamID: "TAKEOVER")
            == .changed(old: "TRUSTED", new: "TAKEOVER"))
        #expect(ledger.teamID(forBundleID: bundleID) == "TRUSTED",
                "SEC-02: reporting a mismatch must not legalize the new Team ID")

        // Re-checking the same unaccepted publisher keeps flagging it against the retained baseline.
        #expect(ledger.record(bundleID: bundleID, teamID: "TAKEOVER")
            == .changed(old: "TRUSTED", new: "TAKEOVER"),
                "SEC-02: the unaccepted publisher must stay rejected on the next check")

        // An unreadable signature (nil Team ID) is still a mismatch and still must not wipe the baseline.
        #expect(ledger.record(bundleID: bundleID, teamID: nil) == .changed(old: "TRUSTED", new: nil))
        #expect(ledger.teamID(forBundleID: bundleID) == "TRUSTED",
                "SEC-02: an unreadable signature cannot erase the known-good baseline")
    }

    // MARK: Snapshot retention (Sources/MacUpdaterCore/BundleSnapshot.swift)

    /// The mismatch rollback restores from a *working copy* of the snapshot
    /// (`CaskRollbackGuard.restore(..., preservingSnapshot: true)`) precisely because
    /// `BundleSnapshot.restore` consumes the bundle handed to it. Cloning first must
    /// leave the app rolled back to the trusted build **and** the original snapshot
    /// intact on disk for manual recovery. Uses only the real `BundleSnapshot` API on
    /// the filesystem, mirroring the app-target sequence this bundle cannot import.
    @Test func mismatchRollbackFromAWorkingCopyKeepsTheOriginalSnapshot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("wega-qa01d-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // The trusted build that was installed before the upgrade.
        let installedApp = root.appendingPathComponent("Figma.app", isDirectory: true)
        try makeBundle(at: installedApp, payload: "trusted-v1")

        // Pre-upgrade snapshot, exactly as CaskRollbackGuard.snapshot(...) clones it.
        let snapshot = root
            .appendingPathComponent("wega-rollback", isDirectory: true)
            .appendingPathComponent("figma.app", isDirectory: true)
        try BundleSnapshot.clone(installedApp, to: snapshot)

        // brew replaced the bundle with a build carrying a DIFFERENT publisher's Team ID.
        try makeBundle(at: installedApp, payload: "takeover-v2")

        // Publisher-mismatch rollback: restore from a working copy so the snapshot survives.
        let workingCopy = snapshot.deletingLastPathComponent()
            .appendingPathComponent("restore-\(UUID().uuidString).app", isDirectory: true)
        try BundleSnapshot.clone(snapshot, to: workingCopy)
        try BundleSnapshot.restore(snapshot: workingCopy, to: installedApp)

        let rolledBack = try payload(of: installedApp)
        #expect(rolledBack == "trusted-v1",
                "SEC-02: the app is restored to the trusted pre-upgrade build")

        #expect(fm.fileExists(atPath: snapshot.path),
                "SEC-02: the original snapshot is retained after the mismatch rollback")
        let retained = try payload(of: snapshot)
        #expect(retained == "trusted-v1",
                "SEC-02: the retained snapshot still holds the recoverable old version")
    }

    // MARK: Wiring — the production mismatch branch composes both guarantees

    /// The behavioural tests above prove the two mechanisms in isolation; this pins the
    /// actual decision path. In the `.changed` branch of `CaskRollbackGuard.verify` the
    /// rollback must preserve the snapshot and the branch must never record (legalize)
    /// the new Team ID or delete the snapshot. LT-01 moved the healthy branch's snapshot
    /// deletion out: the retention sweep owns committed snapshots now, so the healthy
    /// branch's remaining job here is the ledger update.
    @Test func mismatchBranchOfCaskRollbackGuardRetainsBaselineAndSnapshot() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/CaskRollbackGuard.swift"),
            encoding: .utf8)

        let branchStart = try #require(source.range(of: "case let .changed(old, new):"))
        let branchEnd = try #require(source.range(
            of: "case .firstSeen, .unchanged:",
            range: branchStart.upperBound..<source.endIndex))
        let mismatchBranch = source[branchStart.lowerBound..<branchEnd.lowerBound]
        let healthyBranch = source[branchEnd.lowerBound...]

        #expect(mismatchBranch.contains("preservingSnapshot: true"),
                "SEC-02: a publisher mismatch must roll back on a preserved working copy")
        #expect(!mismatchBranch.contains("removeItem"),
                "SEC-02: the mismatch branch must not delete the rollback snapshot")
        #expect(!mismatchBranch.contains("TeamIDLedger.shared.record"),
                "SEC-02: the mismatch branch must not legalize the new publisher")

        #expect(!healthyBranch.contains("removeItem(at: snapshotURL)"),
                "LT-01: the healthy branch no longer deletes the snapshot — the retention sweep owns it")
        #expect(healthyBranch.contains("TeamIDLedger.shared.record"),
                "SEC-02: only a healthy upgrade advances the trusted baseline")
    }

    // MARK: Helpers

    private func makeBundle(at url: URL, payload: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: url.appendingPathComponent("payload"))
    }

    private func payload(of bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("payload"), encoding: .utf8)
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
