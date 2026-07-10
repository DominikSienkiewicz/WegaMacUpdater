import XCTest
@testable import MacUpdaterCore

/// M4 — one count, described the same way everywhere.
///
/// The window header, the sidebar badge, the menu-bar badge and the notification each used
/// to count something slightly different, so no user could build a mental model of "how
/// many things are wrong". `unifiedCount` is now the single answer, and it is honest about
/// its two halves: `installable` is what the "Update all" button will actually install,
/// `manual` is what Wega found but cannot install for you.
final class UnifiedCountTests: XCTestCase {
    func testTotalIsInstallablePlusManual() {
        let count = UpdatePlanner.unifiedCount(installable: 12, manual: 3)
        XCTAssertEqual(count.total, 15)
    }

    func testInstallableAndManualAreKeptSeparate() {
        let count = UpdatePlanner.unifiedCount(installable: 12, manual: 3)
        XCTAssertEqual(count.installable, 12)
        XCTAssertEqual(count.manual, 3)
    }

    func testNothingOutdatedIsEmpty() {
        XCTAssertTrue(UpdatePlanner.unifiedCount(installable: 0, manual: 0).isEmpty)
    }

    func testAnyManualUpdateMakesItNonEmpty() {
        XCTAssertFalse(UpdatePlanner.unifiedCount(installable: 0, manual: 2).isEmpty)
    }

    /// The button only ever promises what it can deliver.
    func testUpdateAllButtonCountsInstallableOnly() {
        let count = UpdatePlanner.unifiedCount(installable: 12, manual: 3)
        XCTAssertEqual(count.updateAllButtonCount, 12)
    }

    func testUpdateAllButtonIsHiddenWhenNothingIsInstallable() {
        let count = UpdatePlanner.unifiedCount(installable: 0, manual: 3)
        XCTAssertEqual(count.updateAllButtonCount, 0)
    }

    /// The badge carries one number — the total — because a badge has room for one number.
    func testBadgeShowsTheTotal() {
        XCTAssertEqual(UpdatePlanner.unifiedCount(installable: 12, manual: 3).badgeCount, 15)
    }
}
