import Testing
import Foundation
import WegaTestSupport
@testable import MacUpdaterCore

/// Proton Mail regression: Proton moved its Developer ID from 6UN54H93QT (Proton Technologies AG)
/// to 2SB5Z68H26 (Proton AG). The ledger refuses to replace a baseline on a mismatch, and nothing
/// else could — so the cask stayed vetoed forever, listed as "1.15.1 → 1.15.1, cofnięto — ponów
/// próbę", and every "Aktualizuj przez Brew" ended in the same "Team ID zmienił się" refusal.
@Suite("PublisherChangeAcceptance")
struct PublisherChangeAcceptanceTests {
    private let oldTeamID = "6UN54H93QT"
    private let newTeamID = "2SB5Z68H26"

    @Test func userAcceptanceRebaselinesBothNamespaces() {
        let (defaults, teardown) = TestDefaults.isolated("publisher-change-acceptance")
        defer { teardown() }
        let ledger = TeamIDLedger(defaults: defaults)
        ledger.record(bundleID: TeamIDLedger.caskKey("proton-mail"), teamID: oldTeamID)
        ledger.record(bundleID: "ch.protonmail.desktop", teamID: oldTeamID)
        #expect(ledger.record(bundleID: TeamIDLedger.caskKey("proton-mail"), teamID: newTeamID)
            == .changed(old: oldTeamID, new: newTeamID))

        ledger.acceptPublisherChange(keys: [TeamIDLedger.caskKey("proton-mail"), "ch.protonmail.desktop"],
                                     teamID: newTeamID)

        #expect(ledger.record(bundleID: TeamIDLedger.caskKey("proton-mail"), teamID: newTeamID)
            == .unchanged(teamID: newTeamID))
        #expect(ledger.teamID(forBundleID: "ch.protonmail.desktop") == newTeamID)
    }

    @Test func acceptanceIgnoresAnEmptyTeamID() {
        let (defaults, teardown) = TestDefaults.isolated("publisher-change-acceptance-empty")
        defer { teardown() }
        let ledger = TeamIDLedger(defaults: defaults)
        ledger.record(bundleID: "com.x", teamID: oldTeamID)

        ledger.acceptPublisherChange(keys: ["com.x"], teamID: "")

        #expect(ledger.teamID(forBundleID: "com.x") == oldTeamID)
    }

    @Test func installedAppSignedByTheReportedPublisherIsAccepted() {
        let decision = PublisherChangeAcceptance.decide(
            reportedTeamID: newTeamID,
            installedTeamID: newTeamID,
            trustedTeamIDs: [oldTeamID, oldTeamID]
        )
        #expect(decision == .accept(previous: oldTeamID, new: newTeamID))
    }

    @Test func aBannerWithoutTheNewIDStillAcceptsWhatIsOnDisk() {
        let decision = PublisherChangeAcceptance.decide(
            reportedTeamID: nil,
            installedTeamID: newTeamID,
            trustedTeamIDs: [oldTeamID, nil]
        )
        #expect(decision == .accept(previous: oldTeamID, new: newTeamID))
    }

    /// The user agreed to the ID they were shown; a bundle that has since been swapped for a
    /// third publisher must not ride on that consent.
    @Test func aBundleReSignedSinceTheReportIsRefused() {
        let decision = PublisherChangeAcceptance.decide(
            reportedTeamID: newTeamID,
            installedTeamID: "ZZZZZZZZZZ",
            trustedTeamIDs: [oldTeamID]
        )
        #expect(decision == .installedDiffersFromReport(reported: newTeamID, installed: "ZZZZZZZZZZ"))
    }

    @Test func anUnreadableSignatureIsNeverAccepted() {
        let decision = PublisherChangeAcceptance.decide(
            reportedTeamID: newTeamID,
            installedTeamID: nil,
            trustedTeamIDs: [oldTeamID]
        )
        #expect(decision == .signatureUnreadable)
    }

    /// After a rollback the trusted build is back on disk: there is no change left to accept.
    @Test func anInstalledAppMatchingEveryBaselineIsAlreadyTrusted() {
        let decision = PublisherChangeAcceptance.decide(
            reportedTeamID: newTeamID,
            installedTeamID: oldTeamID,
            trustedTeamIDs: [oldTeamID, nil]
        )
        #expect(decision == .alreadyTrusted)
    }
}
