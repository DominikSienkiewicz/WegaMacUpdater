import Foundation
import Testing
@testable import MacUpdaterCore

/// QA-01i — regression lock for the REL-07 guarantee: the **decision matrix** of
/// `CaskRollbackGuard.verify` maps every combination of its three sequential gates and the
/// presence of a rollback snapshot to exactly one outcome, and only a fully healthy upgrade
/// is ever allowed to count as one.
///
/// The matrix `verify` walks, in order, is:
///
/// | gate            | condition | snapshot | outcome                                  |
/// |-----------------|-----------|----------|------------------------------------------|
/// | bundle identity | mismatch  | absent   | `.rollbackFailed`                        |
/// | bundle identity | mismatch  | present  | `.rolledBack` / `.rollbackFailed`        |
/// | Gatekeeper      | fails     | absent   | `.rollbackFailed`                        |
/// | Gatekeeper      | fails     | present  | `.rolledBack` / `.rollbackFailed`        |
/// | publisher       | changed   | absent   | `.rollbackFailed`                        |
/// | publisher       | changed   | present  | `.publisherChangedAndRolledBack` / `.rollbackFailed` |
/// | all pass        | —         | retained (LT-01) | `.healthy`                       |
///
/// The verdict this produces is what decides whether the run may announce success, and the
/// worst cell — a check rejects the new build *and* the restore fails — is the one that must
/// never be silent. This suite pins the matrix at both layers, exactly as `QA-01d` does for
/// the publisher branch it shares:
///
///   • the **terminal verdicts** (`.healthy`, `.rolledBack`, `.publisherChangedAndRolledBack`,
///     `.rollbackFailed`) behaviourally, against the real `UpdateRunOutcome` aggregation in
///     `MacUpdaterCore`, because that is where a verdict turns into "upgraded" or "critical";
///   • the **gate → outcome wiring** at source level, because `CaskRollbackGuard.verify` lives
///     in the app target (`Sources/MacUpdater`) that this test bundle cannot import — its
///     inputs (`CanaryCheck.passesGatekeeper`, `CodeSignatureVerifier.teamID`) are live system
///     probes a unit test cannot stand in for.
@Suite("QA-01i — CaskRollbackGuard.verify decision matrix")
struct QA01IRollbackVerifyMatrixTests {

    // MARK: Terminal verdicts (behavioural — MacUpdaterCore)

    /// The only cell that counts as an upgrade. A `.healthy` validation leaves the item on the
    /// new version and raises no critical signal — and is deliberately folded in as a no-op, so
    /// it can never talk a failed install back up into a success.
    @Test func healthyIsTheOnlyVerdictThatCountsAsAnUpgrade() {
        let summary = validated(with: .healthy).summary

        #expect(summary.upgraded.map(\.name) == ["figma"],
                "REL-07: a healthy canary is the one matrix cell that leaves the new version installed")
        #expect(summary.allItemsUpgraded,
                "REL-07: nothing else in the run stands between a healthy item and announced success")
        #expect(summary.critical.isEmpty)
        #expect(summary.rollbackFailures.isEmpty)
    }

    /// A rejected build whose previous version was restored: not an upgrade, and still on disk
    /// as the old version, so the run cannot claim it succeeded.
    @Test func rolledBackNeverCountsAsAnUpgrade() {
        let summary = validated(with: .rolledBack).summary

        #expect(summary.upgraded.isEmpty,
                "REL-07: a rolled-back item is back on the previous version — never upgraded")
        #expect(summary.notUpgraded.map(\.name) == ["figma"])
        #expect(!summary.allItemsUpgraded,
                "REL-07: one rolled-back item is enough to block a green banner")
        #expect(summary.names { $0 == .rolledBack } == ["figma"])
    }

    /// A publisher swap that was caught and undone: not an upgrade, and critical — the
    /// supply-chain warning and the rollback are both facts the user must not miss.
    @Test func publisherChangedAndRolledBackIsCriticalAndNotAnUpgrade() {
        let summary = validated(with: .publisherChangedAndRolledBack(old: "OLDTEAM", new: "NEWTEAM")).summary

        #expect(summary.upgraded.isEmpty,
                "REL-07: a rejected publisher swap leaves the old trusted version installed")
        #expect(summary.critical.map(\.name) == ["figma"],
                "REL-07: rollback must not hide the supply-chain warning")
        #expect(summary.publisherChanges.map(\.name) == ["figma"])
        #expect(summary.names { $0 == .rolledBack } == ["figma"],
                "REL-07: the rollback fact travels alongside the publisher-change fact")
    }

    /// The worst cell in the matrix: a check rejected the new build and the previous one could
    /// not be restored. It must be counted as critical and never silent — the whole reason the
    /// verdict travels into the summary at all.
    @Test func rollbackFailedIsCriticalAndCannotBeSilent() {
        let summary = validated(with: .rollbackFailed).summary

        #expect(summary.upgraded.isEmpty)
        #expect(summary.critical.map(\.name) == ["figma"],
                "REL-07: a failed rollback is the worst case and must reach the user, never a log line")
        #expect(summary.rollbackFailures.map(\.name) == ["figma"])
        #expect(!summary.allItemsUpgraded)
    }

    // MARK: Gate → outcome wiring (source-level — app target)

    /// The bundle-identity gate. It runs *only* for an `.expected` baseline (an `.unchecked`
    /// caller skips it), and a mismatch rolls back on a preserved working copy — `.rolledBack`
    /// when the restore lands, `.rollbackFailed` when it does not, and `.rollbackFailed` with no
    /// snapshot to restore from.
    @Test func bundleIdentityMismatchGateMapsToTheRollbackColumn() throws {
        let gate = try bundleIdentityGate()

        #expect(gate.hasPrefix("if case .expected(let expectedBundleIdentifier) = bundleIdentityBaseline {"),
                "matrix: the identity gate is entered only for an .expected baseline — .unchecked skips it")
        #expect(gate.contains("guard expectedBundleIdentifier == installedBundleIdentifier else {"),
                "matrix: the mismatch is what enters the rollback column")
        #expect(gate.contains("guard let snapshotURL else { return .rollbackFailed }"),
                "matrix: mismatch + no snapshot → .rollbackFailed")
        #expect(gate.contains("preservingSnapshot: true"),
                "matrix: an identity mismatch restores on a preserved working copy")
        #expect(gate.contains("? .rolledBack") && gate.contains(": .rollbackFailed"),
                "matrix: mismatch + snapshot → .rolledBack on success, .rollbackFailed on failure")
    }

    /// The Gatekeeper canary gate. A rejected build rolls back, but — unlike the identity and
    /// publisher gates — it does **not** preserve the snapshot: a plain canary failure has no
    /// baseline to keep for manual recovery, so `restore` consumes it.
    @Test func gatekeeperFailureGateMapsToTheRollbackColumn() throws {
        let gate = try gatekeeperGate()

        #expect(gate.contains("CanaryCheck.passesGatekeeper(appAt: validationURL)"),
                "matrix: the canary is the Gatekeeper probe this gate branches on")
        #expect(gate.contains("guard healthy else {"))
        #expect(gate.contains("guard let snapshotURL else { return .rollbackFailed }"),
                "matrix: canary fails + no snapshot → .rollbackFailed")
        #expect(gate.contains("return await restoreSnapshot(snapshotURL, to: validationURL) ? .rolledBack : .rollbackFailed"),
                "matrix: canary fails + snapshot → .rolledBack on success, .rollbackFailed on failure")
        #expect(!gate.contains("preservingSnapshot"),
                "matrix: a plain canary rollback consumes its snapshot — no baseline to retain")
    }

    /// The publisher gate. A `.changed` audit rolls back on a preserved working copy to
    /// `.publisherChangedAndRolledBack` (or `.rollbackFailed`), while `.firstSeen` / `.unchanged`
    /// is the single healthy exit. LT-01 changed what the healthy exit does with the snapshot:
    /// it used to *delete* it here; now the retention sweep owns it, so a manual undo stays
    /// possible for the whole window.
    @Test func publisherGateMapsChangedToRollbackAndUnchangedToHealthy() throws {
        let gate = try publisherGate()
        let changed = try slice(String(gate), from: "case let .changed(old, new):", to: "case .firstSeen, .unchanged:")
        let healthy = try tail(String(gate), from: "case .firstSeen, .unchanged:")

        #expect(changed.contains("guard let snapshotURL else { return .rollbackFailed }"),
                "matrix: publisher changed + no snapshot → .rollbackFailed")
        #expect(changed.contains("preservingSnapshot: true"),
                "matrix: a publisher change restores on a preserved working copy")
        #expect(changed.contains("? .publisherChangedAndRolledBack(old: old, new: new)")
            && changed.contains(": .rollbackFailed"),
                "matrix: changed + snapshot → .publisherChangedAndRolledBack on success, .rollbackFailed on failure")

        #expect(!healthy.contains("removeItem(at: snapshotURL)"),
                "LT-01: the healthy branch no longer deletes the snapshot — retention owns it now")
        #expect(healthy.contains("return .healthy"),
                "matrix: firstSeen / unchanged is the single healthy exit of the whole matrix")
    }

    /// Which input drives the publisher audit: the shared ledger records (and remembers) the
    /// installed Team ID, while a direct `.expected` baseline compares against a Team ID read
    /// before the mutation — equal means `.unchanged`, otherwise `.changed`.
    @Test func publisherAuditIsDerivedFromTheSelectedBaseline() throws {
        let gate = try publisherGate()

        #expect(gate.contains("TeamIDLedger.shared.record("),
                "matrix: the .ledger column audits against the persisted trusted baseline")
        #expect(gate.contains("expectedTeamID == installedTeamID")
            && gate.contains(".unchanged(teamID: installedTeamID)")
            && gate.contains(".changed(old: expectedTeamID ?? \"—\", new: installedTeamID)"),
                "matrix: the .expected column compares the pre-mutation Team ID — equal is .unchanged, else .changed")
    }

    /// The three gates are evaluated in a fixed order — identity, then Gatekeeper, then
    /// publisher — so a mismatch is caught before the canary and the canary before the
    /// publisher check. The matrix is a sequence, not a set.
    @Test func gatesAreEvaluatedIdentityThenGatekeeperThenPublisher() throws {
        let verify = try privateVerifyBody()

        let identity = try #require(verify.range(of: "= bundleIdentityBaseline {"))
        let gatekeeper = try #require(verify.range(of: "CanaryCheck.passesGatekeeper"))
        let publisher = try #require(verify.range(of: "let installedTeamID = await Task.detached {"))

        #expect(identity.lowerBound < gatekeeper.lowerBound,
                "matrix: the identity gate precedes the Gatekeeper canary")
        #expect(gatekeeper.lowerBound < publisher.lowerBound,
                "matrix: the Gatekeeper canary precedes the publisher check")
    }

    /// Which columns of the matrix each public entry point selects. The batch canary
    /// (`verify(tokens:appPaths:snapshots:)`) runs against the ledger and never checks bundle
    /// identity; the direct replacement entry runs against Team IDs and identifiers captured
    /// before the mutation.
    @Test func publicEntryPointsSelectTheirBaselineColumns() throws {
        let source = try guardSource()

        let batch = try slice(
            source,
            from: "static func verify(\n        tokens: [String],\n        appPaths: [String: URL],\n        snapshots: [String: URL],\n        operation: UpdateOperationSession\n    )",
            to: "/// Verifies a replacement"
        )
        #expect(batch.contains("publisherBaseline: .ledger,")
            && batch.contains("bundleIdentityBaseline: .unchecked"),
                "matrix: the batch canary uses the ledger and skips the identity gate")

        let direct = try slice(
            source,
            from: "expectedTeamID: String?,",
            to: "private static func verify("
        )
        #expect(direct.contains("publisherBaseline: .expected(expectedTeamID),")
            && direct.contains("bundleIdentityBaseline: .expected(expectedBundleIdentifier)"),
                "matrix: the direct replacement entry checks both the expected publisher and identifier")
    }

    // MARK: REL-07 — the decision matrix drives the durable rolled-back mark

    /// REL-07 extends the matrix with a side effect: every terminal verdict is fed to the
    /// persistent `CaskRollbackLedger` at *both* public entry points — the batch canary and
    /// the direct replacement/retry entry — so foreground, background and a conscious retry
    /// all share one rolled-back memory (a rejected build is recorded; a healthy one clears
    /// it). Asserted at source level for the same reason the gates are: `CaskRollbackGuard`
    /// lives in the app target this bundle cannot import. The verdict → mark mapping itself is
    /// pinned behaviourally in `CaskRollbackLedgerTests`.
    @Test func bothPublicEntryPointsDriveTheRollbackLedger() throws {
        let source = try guardSource()

        let batch = try slice(
            source,
            from: "static func verify(\n        tokens: [String],\n        appPaths: [String: URL],\n        snapshots: [String: URL],\n        operation: UpdateOperationSession\n    )",
            to: "/// Verifies a replacement"
        )
        #expect(batch.contains("CaskRollbackLedger.shared.apply(token: token, verdict:"),
                "REL-07: the batch canary records/clears the rolled-back mark for every token it verifies")

        let direct = try slice(
            source,
            from: "expectedTeamID: String?,",
            to: "private static func verify("
        )
        #expect(direct.contains("CaskRollbackLedger.shared.apply(token: token, verdict:"),
                "REL-07: the direct replacement/retry entry records a fresh rollback and clears on a healthy retry")
    }

    // MARK: Behavioural helpers

    /// One cask that brew reported as upgraded, then folded through a canary verdict — the exact
    /// shape both upgrade paths build before reading the summary.
    private func validated(with verdict: CaskValidationVerdict) -> UpdateRunOutcome {
        let item = OutdatedItem(key: "c:figma", name: "figma", from: "1.0", to: "2.0", kind: .cask)
        var run = UpdateRunOutcome()
        run.record([item], outcome: BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: []))
        run.applyValidation(["figma": verdict])
        return run
    }

    // MARK: Source helpers

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func guardSource() throws -> String {
        try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/CaskRollbackGuard.swift"),
            encoding: .utf8
        )
    }

    /// The body of the private three-baseline `verify`, isolated from the public overloads
    /// (whose `snapshotURL` is non-optional) and from the `restore` helper below it.
    private func privateVerifyBody() throws -> Substring {
        try slice(guardSource(), from: "snapshotURL: URL?,", to: "/// Restores in place")
    }

    private func bundleIdentityGate() throws -> Substring {
        try slice(
            String(privateVerifyBody()),
            from: "if case .expected(let expectedBundleIdentifier) = bundleIdentityBaseline {",
            to: "let healthy = await Task.detached {"
        )
    }

    private func gatekeeperGate() throws -> Substring {
        try slice(
            String(privateVerifyBody()),
            from: "let healthy = await Task.detached {",
            to: "let installedTeamID = await Task.detached {"
        )
    }

    private func publisherGate() throws -> Substring {
        try tail(String(privateVerifyBody()), from: "let installedTeamID = await Task.detached {")
    }

    /// The substring of `text` between the first occurrence of `from` and the next occurrence
    /// of `to`, `from` included — locating a region before asserting inside it, so a pattern
    /// can never accidentally match text belonging to a different gate.
    private func slice(_ text: String, from: String, to: String) throws -> Substring {
        let start = try #require(text.range(of: from))
        let region = text[start.lowerBound...]
        let end = try #require(region.range(of: to))
        return region[..<end.lowerBound]
    }

    /// Everything from the first occurrence of `from` to the end of `text`.
    private func tail(_ text: String, from: String) throws -> Substring {
        let start = try #require(text.range(of: from))
        return text[start.lowerBound...]
    }
}
