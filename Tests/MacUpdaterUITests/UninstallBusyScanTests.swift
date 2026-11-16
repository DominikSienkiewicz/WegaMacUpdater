import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

@Suite("Uninstall busy scan")
@MainActor
struct UninstallBusyScanTests {
    @Test func scanRequestedWhileQuittingIsDeclinedNotEmpty() async {
        let coordinator = UninstallCoordinator()
        #expect(coordinator.beginQuitPhase())
        let result: UninstallScan? = await coordinator.scan(using: BrewService())
        #expect(result == nil)
    }
}
