import XCTest
@testable import MacUpdaterCore

/// M5 — the publisher-change alert used to be written into a single `banner` slot and was
/// then clobbered by the upgrade summary before the user could ever read it. A banner that
/// reports a changed Team ID has to outlive whatever the upgrade says afterwards.
final class BannerQueueTests: XCTestCase {
    func testEmptyQueueShowsNothing() {
        let queue = BannerQueue<String>()
        XCTAssertNil(queue.current)
    }

    /// The bug, reproduced: a sticky alert raised mid-upgrade, then the summary banner.
    func testStickyBannerSurvivesALaterTransientBanner() {
        var queue = BannerQueue<String>()
        queue.enqueue("Team ID changed", sticky: true)
        queue.enqueue("Updated 3 packages", sticky: false)

        XCTAssertEqual(queue.current, "Team ID changed")
    }

    func testDismissingTheStickyBannerRevealsTheTransientOne() {
        var queue = BannerQueue<String>()
        queue.enqueue("Team ID changed", sticky: true)
        queue.enqueue("Updated 3 packages", sticky: false)

        queue.dismissCurrent()

        XCTAssertEqual(queue.current, "Updated 3 packages")
    }

    /// Today's behaviour for ordinary banners is "last one wins"; keep it, so a scan that
    /// ends in a summary does not leave a stack of stale notices behind.
    func testTransientBannerReplacesThePreviousTransientOne() {
        var queue = BannerQueue<String>()
        queue.enqueue("Scanning failed", sticky: false)
        queue.enqueue("Updated 3 packages", sticky: false)

        XCTAssertEqual(queue.current, "Updated 3 packages")
        queue.dismissCurrent()
        XCTAssertNil(queue.current)
    }

    func testStickyBannersAreShownInTheOrderTheyWereRaised() {
        var queue = BannerQueue<String>()
        queue.enqueue("Team ID changed: docker", sticky: true)
        queue.enqueue("Team ID changed: postman", sticky: true)

        XCTAssertEqual(queue.current, "Team ID changed: docker")
        queue.dismissCurrent()
        XCTAssertEqual(queue.current, "Team ID changed: postman")
        queue.dismissCurrent()
        XCTAssertNil(queue.current)
    }

    func testDismissingAnEmptyQueueIsHarmless() {
        var queue = BannerQueue<String>()
        queue.dismissCurrent()
        XCTAssertNil(queue.current)
    }

    func testClearingDropsEverythingIncludingStickyBanners() {
        var queue = BannerQueue<String>()
        queue.enqueue("Team ID changed", sticky: true)
        queue.enqueue("Updated 3 packages", sticky: false)

        queue.removeAll()

        XCTAssertNil(queue.current)
    }
}
