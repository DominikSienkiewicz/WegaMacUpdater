import Foundation
import MacUpdaterCore
import Testing
import WegaTestSupport

@testable import WegaMacUpdater

/// Proton Mail regression: the cask was vetoed on every run because its Developer ID moved from
/// 6UN54H93QT to 2SB5Z68H26 and nothing could accept that. The row sat at "1.15.1 → 1.15.1,
/// cofnięto — ponów próbę" and "Aktualizuj przez Brew" only repeated the refusal.
@MainActor
@Suite("PublisherTrustFlow")
struct PublisherTrustFlowTests {
    private static let appURL = URL(fileURLWithPath: "/Applications/Proton Mail.app")

    private struct Fixture {
        let scan: ScanStore
        let teamIDs: TeamIDLedger
        let rollbacks: CaskRollbackLedger
        let prompts: PromptRecorder
    }

    private final class PromptRecorder {
        var prompts: [ScanStore.PublisherChangePrompt] = []
    }

    private func fixture(defaults: UserDefaults, installedTeamID: String?, confirms: Bool) -> Fixture {
        let teamIDs = TeamIDLedger(defaults: defaults)
        let rollbacks = CaskRollbackLedger(defaults: defaults)
        let recorder = PromptRecorder()
        var dependencies = ScanStoreDependencies.live
        dependencies.teamIDOfApp = { _ in installedTeamID }
        dependencies.bundleIdentifierOfApp = { _ in "ch.protonmail.desktop" }
        dependencies.teamIDLedger = teamIDs
        dependencies.rollbackLedger = rollbacks
        dependencies.confirmPublisherChange = { prompt in
            recorder.prompts.append(prompt)
            return confirms
        }
        let scan = ScanStore(dependencies: dependencies)
        scan.manualOutdated = [ManualOutdatedApp(
            name: "Proton Mail",
            path: Self.appURL,
            installedVersion: "1.15.1",
            availableVersion: "1.15.1",
            source: .cask(token: "proton-mail"),
            rolledBack: true
        )]
        teamIDs.record(bundleID: TeamIDLedger.caskKey("proton-mail"), teamID: "6UN54H93QT")
        teamIDs.record(bundleID: "ch.protonmail.desktop", teamID: "6UN54H93QT")
        rollbacks.recordRollback(token: "proton-mail", reason: .publisherChanged)
        return Fixture(scan: scan, teamIDs: teamIDs, rollbacks: rollbacks, prompts: recorder)
    }

    @Test func confirmedTrustRebaselinesClearsTheMarkAndSettlesTheSameVersionRow() async {
        let (defaults, teardown) = TestDefaults.isolated("publisher-trust-flow-accept")
        defer { teardown() }
        let fixture = fixture(defaults: defaults, installedTeamID: "2SB5Z68H26", confirms: true)

        await fixture.scan.trustNewPublisher(token: "proton-mail", reportedTeamID: "2SB5Z68H26")

        #expect(fixture.prompts.prompts == [ScanStore.PublisherChangePrompt(
            token: "proton-mail", previousTeamID: "6UN54H93QT", newTeamID: "2SB5Z68H26")])
        #expect(fixture.teamIDs.teamID(forBundleID: TeamIDLedger.caskKey("proton-mail")) == "2SB5Z68H26")
        #expect(fixture.teamIDs.teamID(forBundleID: "ch.protonmail.desktop") == "2SB5Z68H26")
        #expect(!fixture.rollbacks.isRolledBack(token: "proton-mail"))
        #expect(fixture.scan.manualOutdated.isEmpty)
    }

    @Test func declinedTrustChangesNothing() async {
        let (defaults, teardown) = TestDefaults.isolated("publisher-trust-flow-decline")
        defer { teardown() }
        let fixture = fixture(defaults: defaults, installedTeamID: "2SB5Z68H26", confirms: false)

        await fixture.scan.trustNewPublisher(token: "proton-mail", reportedTeamID: "2SB5Z68H26")

        #expect(fixture.teamIDs.teamID(forBundleID: TeamIDLedger.caskKey("proton-mail")) == "6UN54H93QT")
        #expect(fixture.rollbacks.isRolledBack(token: "proton-mail"))
        #expect(fixture.scan.manualOutdated.count == 1)
    }

    @Test func aBundleReSignedSinceTheWarningIsNeverOfferedForTrust() async {
        let (defaults, teardown) = TestDefaults.isolated("publisher-trust-flow-resigned")
        defer { teardown() }
        let fixture = fixture(defaults: defaults, installedTeamID: "ZZZZZZZZZZ", confirms: true)

        await fixture.scan.trustNewPublisher(token: "proton-mail", reportedTeamID: "2SB5Z68H26")

        #expect(fixture.prompts.prompts.isEmpty)
        #expect(fixture.teamIDs.teamID(forBundleID: TeamIDLedger.caskKey("proton-mail")) == "6UN54H93QT")
        #expect(fixture.rollbacks.isRolledBack(token: "proton-mail"))
    }
}
