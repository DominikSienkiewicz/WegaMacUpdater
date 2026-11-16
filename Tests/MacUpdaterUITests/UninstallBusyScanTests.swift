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

    /// The coordinator refuses a quit phase while it scans, so the sheet's confirm button must
    /// say why it is unavailable instead of doing nothing when pressed.
    @Test func confirmIsUnavailableWhileRefreshing() {
        #expect(UninstallDialog.confirmUnavailableNote(isRefreshing: true) != nil)
        #expect(UninstallDialog.confirmUnavailableNote(isRefreshing: false) == nil)
    }
}
