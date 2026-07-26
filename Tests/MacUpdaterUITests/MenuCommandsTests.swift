import XCTest
@testable import WegaMacUpdater
import MacUpdaterCore

/// UX-10 — keyboard shortcuts and menu items. The `.commands` wiring itself is a SwiftUI
/// scene and not unit-testable, so these tests pin the two pieces of logic behind it: the
/// ⌘1…⌘5 destination mapping, and the ⌘F focus-request bus.
@MainActor
final class MenuCommandsTests: XCTestCase {

    /// ⌘1…⌘5 must map to the five coarse sidebar sections, top to bottom, each exactly once.
    /// The Updates section opens on its unfiltered list.
    func testNumberedDestinationsCoverTheFiveSectionsInOrder() {
        let destinations = WegaMenuNavigation.numberedDestinations

        XCTAssertEqual(destinations.count, 5, "⌘1…⌘5 needs exactly five destinations")
        XCTAssertEqual(
            destinations.map(\.tab),
            [.update, .migration, .inventory, .uninstall, .logs],
            "The numbered destinations must follow the sidebar's top-to-bottom order"
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
