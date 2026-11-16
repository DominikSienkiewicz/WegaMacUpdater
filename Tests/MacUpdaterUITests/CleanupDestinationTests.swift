import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

final class CleanupDestinationTests: XCTestCase {
    func testCleanupHasLabelIconAndTab() {
        XCTAssertEqual(SidebarSelection.cleanup.tab, .cleanup)
        XCTAssertEqual(SidebarSelection.forTab(.cleanup), .cleanup)
        XCTAssertEqual(SidebarSelection.cleanup.systemImage, "sparkles")
        XCTAssertEqual(SidebarSelection.cleanup.label, "Porządki")
        XCTAssertEqual(Translations.en["Porządki"], "Cleanup")
        XCTAssertEqual(Translations.en["Duplikaty i pozostałości"], "Duplicates and leftovers")
        XCTAssertEqual(Translations.en["Posprzątam po aktualizacjach."], "I'll tidy up after updates.")
    }

    func testCleanupHintAndWegaLineAreLocalisedStrings() {
        XCTAssertEqual(SidebarSelection.cleanup.hint, tr("Duplikaty i pozostałości"))
        XCTAssertEqual(WegaState.forTab(.cleanup).line, tr("Posprzątam po aktualizacjach."))
    }
}
