import XCTest
@testable import MacUpdaterCore

/// M2 — showing a restored list instantly is only honest if the list says how old it is.
/// The named risk in the strategy is exactly this: "stara lista musi mieć wyraźny
/// timestamp". A result from yesterday must never look like a result from a moment ago.
final class ScanFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)  // fixed, no clock reads

    func testAScanFromSecondsAgoIsFresh() {
        XCTAssertEqual(ScanFreshness.of(scannedAt: now.addingTimeInterval(-30), now: now), .fresh)
    }

    func testAScanFromFiveMinutesAgoIsFresh() {
        XCTAssertEqual(ScanFreshness.of(scannedAt: now.addingTimeInterval(-5 * 60), now: now), .fresh)
    }

    /// An hour is long enough for the world to have changed; say when it was.
    func testAScanFromAnHourAgoIsRecent() {
        XCTAssertEqual(ScanFreshness.of(scannedAt: now.addingTimeInterval(-60 * 60), now: now), .recent)
    }

    func testAScanFromYesterdayIsStale() {
        XCTAssertEqual(ScanFreshness.of(scannedAt: now.addingTimeInterval(-26 * 60 * 60), now: now), .stale)
    }

    func testAScanFromLastWeekIsStale() {
        XCTAssertEqual(ScanFreshness.of(scannedAt: now.addingTimeInterval(-7 * 24 * 60 * 60), now: now), .stale)
    }

    /// A stale result is the one that has to shout; a fresh one needs no excuse.
    func testOnlyNonFreshResultsNeedAnExplicitTimestamp() {
        XCTAssertFalse(ScanFreshness.fresh.needsExplicitTimestamp)
        XCTAssertTrue(ScanFreshness.recent.needsExplicitTimestamp)
        XCTAssertTrue(ScanFreshness.stale.needsExplicitTimestamp)
    }

    /// Clock skew (a snapshot stamped in the future) must not read as ancient.
    func testAFutureTimestampIsTreatedAsFresh() {
        XCTAssertEqual(ScanFreshness.of(scannedAt: now.addingTimeInterval(120), now: now), .fresh)
    }

    /// Exactly at the boundary the older bucket wins — never claim more freshness than we have.
    func testTheFreshnessBoundaryFavoursTheOlderBucket() {
        XCTAssertEqual(ScanFreshness.of(scannedAt: now.addingTimeInterval(-15 * 60), now: now), .recent)
        XCTAssertEqual(ScanFreshness.of(scannedAt: now.addingTimeInterval(-24 * 60 * 60), now: now), .stale)
    }
}
