import Foundation
import Testing
@testable import MacUpdaterCore

/// BG-01 — an unattended upgrade is allowed only while its rollback net is real.
///
/// A resolved bundle and a successfully created snapshot are separate gates: finding an
/// app does not prove that `clonefile` succeeded. The background executor must also repeat
/// mutable policy and liveness checks after it owns the upgrade mutex, and a global brew
/// failure invalidates the entire unattended batch.
@Suite("BackgroundUpdateSafety")
struct BackgroundUpdateSafetyTests {
    private func item(_ name: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: .cask), name: name,
                     from: "1.0", to: "2.0", kind: .cask)
    }

    private func profile(_ token: String, _ kinds: [CaskArtifactKind]) -> CaskArtifactProfile {
        CaskArtifactProfile(token: token, artifacts: kinds.map { CaskArtifact(kind: $0) })
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func backgroundUpdaterSource() throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/BackgroundUpdater.swift"),
                   encoding: .utf8)
    }

    @Test func binaryOnlyCaskIsNeverEligibleForUnattendedUpgrade() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("codex", [.binary]),
            download: CaskDownloadInfo(token: "codex", url: "https://example.test/codex.zip",
                                       sha256: String(repeating: "a", count: 64))
        )

        #expect(verdict == .ineligible(.noAppBundle))
    }

    @Test func tokenWithoutResolvedAppPathIsVetoed() {
        let appPaths = ["figma": URL(fileURLWithPath: "/Applications/Figma.app")]

        #expect(BackgroundUpdateSafety.pathBackedTokens(["figma", "slack"], appPaths: appPaths) == ["figma"])
    }

    @Test func tokenWithoutConfirmedSnapshotIsVetoed() {
        let snapshots = ["figma": URL(fileURLWithPath: "/tmp/wega-rollback/figma.app")]

        #expect(BackgroundUpdateSafety.snapshotBackedTokens(["figma", "slack"], snapshots: snapshots) == ["figma"])
    }

    @Test func policyAndProcessVetoesAreRepeatedAfterTheMutexIsAcquired() throws {
        let source = try backgroundUpdaterSource()
        let lock = try #require(source.range(of: "guard UpgradeMutex.shared.acquire()"))
        let policies = try #require(source.range(of: "let lockedPolicies = UpdatePolicyStore.shared.policiesMap"))
        let processes = try #require(source.range(of: "let lockedRunningProcessTokens = runningTokens(appPaths: appPaths)"))

        #expect(lock.lowerBound < policies.lowerBound)
        #expect(lock.lowerBound < processes.lowerBound)
        #expect(source.contains("policies: lockedPolicies"))
        #expect(source.contains("runningProcessTokens: lockedRunningProcessTokens"))
    }

    @Test func executorAppliesBothRollbackVetoesBeforeStartingBrew() throws {
        let source = try backgroundUpdaterSource()
        let pathVeto = try #require(source.range(of: "BackgroundUpdateSafety.pathBackedTokens("))
        let snapshot = try #require(source.range(of: "CaskRollbackGuard.snapshot("))
        let snapshotVeto = try #require(source.range(of: "BackgroundUpdateSafety.snapshotBackedTokens("))
        let brew = try #require(source.range(of: "outcome: await runBrew(arguments: arguments)"))

        #expect(pathVeto.lowerBound < snapshot.lowerBound)
        #expect(snapshot.lowerBound < snapshotVeto.lowerBound)
        #expect(snapshotVeto.lowerBound < brew.lowerBound)
    }

    @Test func globalBrewFailureInvalidatesEveryTokenInBackgroundRound() {
        var run = UpdateRunOutcome()
        run.recordBackgroundRound(
            [item("figma"), item("slack")],
            outcome: BrewUpgradeOutcome(exitCode: 1, failedTokens: ["figma"],
                                        errorLines: ["Error: figma: boom"])
        )

        #expect(run.summary.upgraded.isEmpty)
        #expect(run.summary.notUpgraded.map(\.name) == ["figma", "slack"])
    }
}
