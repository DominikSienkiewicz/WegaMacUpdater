import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

/// SEC-02 — detecting a publisher change must not turn the new publisher into the
/// trusted baseline or throw away the only copy that can restore the old app.
@Suite("Publisher baseline protection")
struct PublisherBaselineProtectionTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func publisherMismatchNeverReplacesTheTrustedBaseline() throws {
        let (defaults, teardown) = TestDefaults.isolated("sec02-publisher-baseline")
        defer { teardown() }

        let ledger = TeamIDLedger(defaults: defaults)
        #expect(ledger.record(bundleID: "cask:figma", teamID: "OLDTEAM") == .firstSeen(teamID: "OLDTEAM"))
        #expect(ledger.record(bundleID: "cask:figma", teamID: "NEWTEAM")
            == .changed(old: "OLDTEAM", new: "NEWTEAM"))
        #expect(ledger.teamID(forBundleID: "cask:figma") == "OLDTEAM",
                "SEC-02: reporting a mismatch must not legalize the new Team ID")
        #expect(ledger.record(bundleID: "cask:figma", teamID: "NEWTEAM")
            == .changed(old: "OLDTEAM", new: "NEWTEAM"),
                "SEC-02: the same unaccepted publisher must still be rejected on the next check")
    }

    @Test func oldPublisherIsCapturedBeforeEitherUpgradePathMutatesTheApp() throws {
        let guardSource = try source("Sources/MacUpdater/CaskRollbackGuard.swift")
        let oldPublisherRead = try #require(guardSource.range(of: "CodeSignatureVerifier.teamID(ofAppAt: appURL)"))
        let snapshotClone = try #require(guardSource.range(of: "BundleSnapshot.clone(appURL, to: dest)"))
        #expect(oldPublisherRead.lowerBound < snapshotClone.lowerBound,
                "SEC-02: read the installed app's Team ID before taking the pre-upgrade snapshot")

        // ARCH-08 split the foreground upgrade into a preparation phase and a per-cask lane,
        // so "before" stopped being two statements in one body whose offsets can be compared
        // and became a data dependency. Two facts carry it: the phase that snapshots starts
        // no brew process, and the only lane that does cannot be entered without the
        // snapshots it is handed.
        let rollback = try source("Sources/MacUpdater/ScanStore+Rollback.swift")
        #expect(rollback.contains("let snapshots = snapshotCasks("),
                "SEC-02: the pre-upgrade snapshot is taken in the preparation phase")
        #expect(!rollback.contains("runBrewUpgrade("),
                "SEC-02: the preparation phase must not mutate an app it has not snapshotted yet")

        let lanes = try source("Sources/MacUpdater/ScanStore+UpgradeLanes.swift")
        #expect(lanes.contains("func upgradeOneCask(\n        item: OutdatedItem,\n        appPaths: [String: URL],\n        snapshots: [String: URL],"),
                "SEC-02: the foreground path must capture the old publisher before brew mutates the app")

        let background = try source("Sources/MacUpdater/BackgroundUpdater.swift")
        let backgroundSnapshot = try #require(background.range(of: "CaskRollbackGuard.snapshot("))
        let backgroundMutation = try #require(background.range(
            of: "var caskOutcome = await runBrew(arguments: arguments)"))
        #expect(backgroundSnapshot.lowerBound < backgroundMutation.lowerBound,
                "SEC-02: the background path must capture the old publisher before brew mutates the app")
    }

    @Test func publisherMismatchRollsBackWithoutExplicitlyDeletingTheSnapshot() throws {
        let guardSource = try source("Sources/MacUpdater/CaskRollbackGuard.swift")

        #expect(guardSource.contains("case let .changed(old, new)"))
        #expect(guardSource.contains("preservingSnapshot: true"),
                "SEC-02: publisher mismatch must enter the rollback path")
        #expect(guardSource.contains("BundleSnapshot.clone(snapshot, to: restorationSource)"),
                "SEC-02: rollback must consume a working copy and retain the original snapshot")
        #expect(guardSource.contains(".publisherChangedAndRolledBack(old: old, new: new)"),
                "SEC-02: the result must preserve both the security alert and successful rollback")
        #expect(!guardSource.contains(
            "if let snapshot = snapshots[token] { try? FileManager.default.removeItem(at: snapshot) }"),
                "SEC-02: cleanup must not unconditionally delete the rollback snapshot after a mismatch")
    }

    @Test func publisherRollbackRemainsVisibleAndCannotCountAsAnUpgrade() {
        let item = OutdatedItem(key: "c:figma", name: "figma", from: "1.0", to: "2.0", kind: .cask)
        var run = UpdateRunOutcome()
        run.record([item], outcome: BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: []))
        run.applyValidation([
            "figma": .publisherChangedAndRolledBack(old: "OLDTEAM", new: "NEWTEAM"),
        ])

        let summary = run.summary
        #expect(summary.upgraded.isEmpty,
                "SEC-02: a rejected publisher swap leaves the old version installed")
        #expect(summary.notUpgraded.map(\.name) == ["figma"])
        #expect(summary.critical.map(\.name) == ["figma"],
                "SEC-02: rollback must not hide the supply-chain warning")
        #expect(summary.publisherChanges.map(\.name) == ["figma"])
        #expect(summary.names { $0 == .rolledBack } == ["figma"])
    }

    @Test func failedBackgroundRoundKeepsBothFailureAndPublisherRollbackFacts() {
        let item = OutdatedItem(key: "c:figma", name: "figma", from: "1.0", to: "2.0", kind: .cask)
        var run = UpdateRunOutcome()
        run.recordBackgroundRound(
            [item],
            outcome: BrewUpgradeOutcome(exitCode: 1, failedTokens: ["figma"], errorLines: ["boom"])
        )
        run.applyValidation([
            "figma": .publisherChangedAndRolledBack(old: "OLDTEAM", new: "NEWTEAM"),
        ])

        let summary = run.summary
        #expect(summary.items.map(\.verdict) == [
            .executionFailedAfterPublisherRollback(old: "OLDTEAM", new: "NEWTEAM"),
        ])
        #expect(summary.publisherChanges.map(\.name) == ["figma"])
        #expect(summary.names { $0 == .executionFailed } == ["figma"])
        #expect(summary.names { $0 == .rolledBack } == ["figma"])
    }

    @Test func preexistingPublisherMismatchVetoesBothUpgradePathsBeforeBrew() throws {
        // A vetoed cask no longer has to beat brew to the app: the veto runs in the
        // preparation phase and its tokens are filtered out of the trusted set the lane is
        // handed, so by the time any process starts there is no plan entry left to pick up.
        let rollback = try source("Sources/MacUpdater/ScanStore+Rollback.swift")
        let foregroundVeto = try #require(rollback.range(
            of: "let publisherVetoes = CaskRollbackGuard.publisherVetoes("))
        let trustedFilter = try #require(rollback.range(
            of: "let caskNames = caskNames.filter { publisherVetoes[$0] == nil }"))
        #expect(foregroundVeto.lowerBound < trustedFilter.lowerBound)
        #expect(rollback.contains("trustedCaskNames: caskNames"),
                "SEC-02: only the tokens that survived the veto reach the cask lane")
        #expect(try ScanStoreSources.everything().contains("run.recordPublisherVetoes("),
                "SEC-02: a foreground veto needs a critical per-item outcome")

        let background = try source("Sources/MacUpdater/BackgroundUpdater.swift")
        let backgroundVeto = try #require(background.range(
            of: "let publisherVetoes = CaskRollbackGuard.publisherVetoes("))
        let backgroundMutation = try #require(background.range(
            of: "var caskOutcome = await runBrew(arguments: arguments)"))
        #expect(backgroundVeto.lowerBound < backgroundMutation.lowerBound)
        #expect(background.contains("run.recordPublisherVetoes("),
                "SEC-02: a background veto needs a critical per-item outcome")
    }

    @Test func preexistingPublisherMismatchIsCriticalWithoutClaimingMutationOrRollback() {
        let item = OutdatedItem(key: "c:figma", name: "figma", from: "1.0", to: "2.0", kind: .cask)
        var run = UpdateRunOutcome()
        run.recordPublisherVetoes([item], audits: [
            "figma": .changed(old: "TRUSTED", new: "INSTALLED"),
        ])

        let summary = run.summary
        #expect(summary.items.map(\.verdict) == [
            .publisherMismatchBeforeUpgrade(old: "TRUSTED", current: "INSTALLED"),
        ])
        #expect(summary.upgraded.isEmpty,
                "SEC-02: a preflight veto must never count as an executed upgrade")
        #expect(summary.critical.map(\.name) == ["figma"])
        #expect(summary.publisherChanges.map(\.name) == ["figma"])
        #expect(summary.names { $0 == .rolledBack }.isEmpty,
                "SEC-02: no rollback happened because brew never ran")
    }

    /// Reads the published documentation as one text, for the same reason QA-04 does: README is
    /// a router now and this claim lives in `docs/features.md`. Pinning the file instead of the
    /// claim would mean a section move silently retires the guard.
    private static let publishedDocuments = [
        "README.md",
        "docs/how-it-works.md",
        "docs/features.md",
        "docs/architecture.md",
        "docs/building.md",
        "docs/distribution.md",
    ]

    private func publishedDocumentation() throws -> String {
        try Self.publishedDocuments.map { try source($0) }.joined(separator: "\n")
    }

    @Test func readmeDoesNotClaimMismatchSnapshotsAlwaysEndWithTheCanaryWindow() throws {
        let readme = try publishedDocumentation()
        #expect(!readme.contains("because the snapshot lives only for the canary window"))
        #expect(readme.contains("After a publisher mismatch, the original snapshot remains"))
    }
}
