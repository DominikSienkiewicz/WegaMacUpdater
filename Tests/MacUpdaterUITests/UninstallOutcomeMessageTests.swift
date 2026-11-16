import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

@Suite("Uninstall outcome message and busy scan")
@MainActor
struct UninstallOutcomeMessageTests {
    @Test func mixedSkippedAndFailedNamesBoth() throws {
        let message = try #require(UninstallOutcomeMessage.compose(
            failure: "Odinstalowanie niepełne — nie usunięto: Broken",
            leftoverNote: nil,
            skippedNames: ["Stubborn"]
        ))
        #expect(message.contains("Broken"))
        #expect(message.contains("Stubborn"))
    }

    @Test func nothingToReportIsNil() {
        #expect(UninstallOutcomeMessage.compose(failure: nil, leftoverNote: nil, skippedNames: []) == nil)
    }

    @Test func scanRequestedWhileQuittingIsDeclinedNotEmpty() async {
        let coordinator = UninstallCoordinator()
        #expect(coordinator.beginQuitPhase())
        let result: UninstallScan? = await coordinator.scan(using: BrewService())
        #expect(result == nil)
    }
}
