import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-02 — that the launch smoke test is actually *in* the canary chain, and where.
///
/// The decision logic is pinned behaviourally in `LT02LaunchSmokeTestTests`; the wiring can
/// only be read at source level, for the same reason `QA-01i` reads the rest of the decision
/// matrix that way: `CaskRollbackGuard` lives in the app target (`Sources/MacUpdater`) that
/// this bundle cannot import, and its other inputs are live system probes.
///
/// Two properties matter here, and neither is visible from Core alone:
///
///   * the smoke test runs **last**, after identity, Gatekeeper and publisher. A bundle whose
///     identity or publisher is in doubt is the last thing that should be executed, so the
///     only builds ever started are ones the other three gates approved;
///   * its failure lands in the **existing** rollback path — `restoreSnapshot` inside
///     `verify`, whose verdict already reaches `CaskRollbackLedger` and the LT-01 journal —
///     rather than opening a second way to undo an update.
@Suite("LT-02 — the smoke test is the canary's fourth gate")
struct LT02CanarySmokeGateWiringTests {

    /// Order. The smoke test is the only gate that runs the artifact, so it goes behind every
    /// gate that decides whether the artifact is trustworthy at all.
    @Test func theSmokeTestRunsAfterIdentityGatekeeperAndPublisher() throws {
        let verify = try privateVerifyBody()

        let identity = try #require(verify.range(of: "= bundleIdentityBaseline {"))
        let gatekeeper = try #require(verify.range(of: "CanaryCheck.passesGatekeeper"))
        let publisher = try #require(verify.range(of: "let installedTeamID = await Task.detached {"))
        let smokeTest = try #require(verify.range(of: "await launchSmokeTest(token: token, appURL: validationURL)"))

        #expect(identity.lowerBound < gatekeeper.lowerBound)
        #expect(gatekeeper.lowerBound < publisher.lowerBound)
        #expect(publisher.lowerBound < smokeTest.lowerBound,
                "LT-02: only a build the identity, Gatekeeper and publisher gates approved is ever started")
    }

    /// A failed smoke test is a rollback, decided by the same `requiresRollback` policy the
    /// Core tests pin — and carried out by the same `restoreSnapshot` every other gate uses,
    /// so the verdict keeps flowing into the ledger and the LT-01 journal untouched.
    @Test func aFailedSmokeTestRollsBackThroughTheExistingChain() throws {
        let healthyBranch = try tail(String(privateVerifyBody()), from: "case .firstSeen, .unchanged:")

        #expect(healthyBranch.contains("guard !LaunchSmokeTest.requiresRollback(smokeTest) else {"),
                "LT-02: what counts as a failure is Core's policy, not a second opinion spelled out here")
        #expect(healthyBranch.contains("return await restoreSnapshot(snapshotURL, to: validationURL) ? .rolledBack : .rollbackFailed"),
                "LT-02: the smoke test joins the existing rollback path instead of opening a second one")
        #expect(healthyBranch.contains("return .healthy"),
                "LT-02: surviving the window is still the single healthy exit of the whole matrix")
    }

    /// Without a snapshot there is nothing the verdict could be spent on, and starting an app
    /// has a cost — so the gate stands down rather than running a check it cannot act on.
    @Test func withoutASnapshotTheAppIsNotStartedAtAll() throws {
        let healthyBranch = try tail(String(privateVerifyBody()), from: "case .firstSeen, .unchanged:")
        let guardClause = try #require(healthyBranch.range(of: "guard let snapshotURL else { return .healthy }"))
        let launch = try #require(healthyBranch.range(of: "await launchSmokeTest("))

        #expect(guardClause.lowerBound < launch.lowerBound,
                "LT-02: the snapshot is checked before the app is started, not after")
    }

    /// The switch is honoured inside the guard, and a switched-off gate is a skip — never a
    /// verdict that could undo an upgrade.
    @Test func theSwitchIsReadBeforeAnythingIsLaunched() throws {
        let helper = try tail(try guardSource(), from: "private static func launchSmokeTest(")

        #expect(helper.contains("guard LaunchSmokeTestConfiguration.isEnabled() else { return .skipped(.disabled) }"),
                "LT-02: the opt-out is read before the app is started")
        #expect(!LaunchSmokeTest.requiresRollback(.skipped(.disabled)),
                "LT-02: a gate the user switched off can never be a reason to roll back")
        #expect(helper.contains("WorkspaceAppLaunchProbe()"),
                "LT-02: the production probe is the hidden, non-activating NSWorkspace launch")
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

    private func privateVerifyBody() throws -> Substring {
        try slice(guardSource(), from: "snapshotURL: URL?,", to: "/// Restores in place")
    }

    private func slice(_ text: String, from: String, to: String) throws -> Substring {
        let start = try #require(text.range(of: from))
        let region = text[start.lowerBound...]
        let end = try #require(region.range(of: to))
        return region[..<end.lowerBound]
    }

    private func tail(_ text: String, from: String) throws -> Substring {
        let start = try #require(text.range(of: from))
        return text[start.lowerBound...]
    }
}
