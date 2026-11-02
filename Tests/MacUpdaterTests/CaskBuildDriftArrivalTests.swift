import Testing
@testable import MacUpdaterCore

@Suite("Cask drift repair verifies the offered build")
struct CaskBuildDriftArrivalTests {
    @Test(arguments: [
        ("0.4.16+1", "0.4.16,2"),
        ("1.2.3-beta", "1.2.3"),
    ])
    func unchangedOlderBuildDoesNotBecomeASuccess(installed: String, offered: String) {
        #expect(CaskAdoptionCommand.arguments(
            token: "example", offeredVersion: offered, recordedVersion: offered
        ) == BrewService.reinstallCaskArguments(token: "example"))

        #expect(UpdateOperationRecoveryPlan.installedNothing(
            evidence: .forcedReinstall(expectedVersion: offered),
            installedVersion: installed,
            snapshotVersion: installed
        ), "a matching Caskroom receipt does not prove the offered build arrived on disk")
    }

    @Test func anArrivedBuildIsNotMistakenForTheUnchangedSnapshot() {
        #expect(!UpdateOperationRecoveryPlan.installedNothing(
            evidence: .forcedReinstall(expectedVersion: "0.4.16,2"),
            installedVersion: "0.4.16+2",
            snapshotVersion: "0.4.16+1"
        ))
    }

    @Test func equivalentBuildEncodingRemainsAValidTakeover() {
        #expect(!UpdateOperationRecoveryPlan.installedNothing(
            evidence: .forcedReinstall(expectedVersion: "0.4.16,2"),
            installedVersion: "0.4.16+2",
            snapshotVersion: "0.4.16+2"
        ))
    }
}
