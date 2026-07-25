import Foundation
import Testing
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
        let suiteName = "wega-sec-02-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

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

        let foreground = try source("Sources/MacUpdater/ScanStore+Actions.swift")
        let foregroundSnapshot = try #require(foreground.range(of: "let snapshots = snapshotCasks("))
        let foregroundMutation = try #require(foreground.range(
            of: "var caskOutcome = await runBrewUpgrade(arguments: trustedCaskArgs)"))
        #expect(foregroundSnapshot.lowerBound < foregroundMutation.lowerBound,
                "SEC-02: the foreground path must capture the old publisher before brew mutates the app")

        let background = try source("Sources/MacUpdater/BackgroundUpdater.swift")
        let backgroundSnapshot = try #require(background.range(of: "CaskRollbackGuard.snapshot("))
        let backgroundMutation = try #require(background.range(
            of: "outcome: await runBrew(arguments: arguments)"))
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
        let foreground = try source("Sources/MacUpdater/ScanStore+Actions.swift")
        let foregroundVeto = try #require(foreground.range(
            of: "let publisherVetoes = CaskRollbackGuard.publisherVetoes("))
        let foregroundMutation = try #require(foreground.range(
            of: "var caskOutcome = await runBrewUpgrade(arguments: trustedCaskArgs)"))
        #expect(foregroundVeto.lowerBound < foregroundMutation.lowerBound)
        #expect(foreground.contains("run.recordPublisherVetoes("),
                "SEC-02: a foreground veto needs a critical per-item outcome")

        let background = try source("Sources/MacUpdater/BackgroundUpdater.swift")
        let backgroundVeto = try #require(background.range(
            of: "let publisherVetoes = CaskRollbackGuard.publisherVetoes("))
        let backgroundMutation = try #require(background.range(
            of: "outcome: await runBrew(arguments: arguments)"))
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

    @Test func readmeDoesNotClaimMismatchSnapshotsAlwaysEndWithTheCanaryWindow() throws {
        let readme = try source("README.md")
        #expect(!readme.contains("because the snapshot lives only for the canary window"))
        #expect(readme.contains("After a publisher mismatch, the original snapshot remains"))
    }
}
