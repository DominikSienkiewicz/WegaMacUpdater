import XCTest
@testable import WegaMacUpdater
import MacUpdaterCore

/// UX-10 — keyboard shortcuts and menu items. The `.commands` wiring itself is a SwiftUI
/// scene and not unit-testable, so these tests pin the two pieces of logic behind it: the
/// ⌘1…⌘6 destination mapping, and the ⌘F focus-request bus.
@MainActor
final class MenuCommandsTests: XCTestCase {

    /// ⌘1…⌘6 must map to the coarse sidebar sections, top to bottom, each exactly once. The
    /// Updates section opens on its unfiltered list.
    ///
    /// The count grew from five when „Cofnij aktualizacje” became a destination of its own;
    /// what this pins has not changed. The numbers follow the sidebar, so a new section is
    /// expected to take its place in the middle and push the ones below it down a digit —
    /// the failure this guards against is a *visible* destination that no number reaches.
    func testNumberedDestinationsCoverEverySectionInSidebarOrder() {
        let destinations = WegaMenuNavigation.numberedDestinations

        XCTAssertEqual(
            destinations.map(\.tab),
            [.update, .migration, .inventory, .rollback, .uninstall, .logs],
            "The numbered destinations must follow the sidebar's top-to-bottom order"
        )
        XCTAssertEqual(
            Set(destinations.map(\.tab)),
            Set(SidebarSelection.allCases.map(\.tab)),
            "Every sidebar section must be reachable by a number key"
        )
        XCTAssertEqual(destinations.first, .updates(.all), "⌘1 opens the unfiltered Updates list")
        XCTAssertEqual(
            Set(destinations.map(\.tab)).count,
            destinations.count,
            "No section is reachable by two different number keys"
        )
    }

    /// ⌘F leaves a single pending focus request that the inventory consumes exactly once —
    /// so navigating to the inventory (which mounts its search field afresh) still focuses it,
    /// without re-stealing focus on the next unrelated appearance.
    func testInventorySearchFocusRequestIsConsumedOnce() {
        let center = WegaCommandCenter()

        XCTAssertFalse(center.consumePendingInventorySearchFocus(), "no request has been made yet")

        center.requestInventorySearchFocus()
        XCTAssertTrue(center.consumePendingInventorySearchFocus(), "the pending ⌘F is consumed")
        XCTAssertFalse(center.consumePendingInventorySearchFocus(), "it is not consumed twice")

        center.requestInventorySearchFocus()
        XCTAssertTrue(center.consumePendingInventorySearchFocus(), "a fresh ⌘F is available again")
    }
}
