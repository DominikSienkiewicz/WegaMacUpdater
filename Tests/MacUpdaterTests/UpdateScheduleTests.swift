import XCTest
@testable import MacUpdaterCore

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let hour: TimeInterval = 3600

    // MARK: shouldCheck

    func testNeverCheckedIsAlwaysDue() {
        XCTAssertTrue(UpdateSchedule.shouldCheck(lastCheck: nil, interval: hour, now: now))
    }

    func testNotDueWhenIntervalHasNotElapsed() {
        let last = now.addingTimeInterval(-1800) // 30 min ago
        XCTAssertFalse(UpdateSchedule.shouldCheck(lastCheck: last, interval: hour, now: now))
    }

    func testDueWhenIntervalElapsed() {
        let last = now.addingTimeInterval(-3600) // exactly 1h ago
        XCTAssertTrue(UpdateSchedule.shouldCheck(lastCheck: last, interval: hour, now: now))
    }

    func testZeroIntervalIsNeverDue() {
        XCTAssertFalse(UpdateSchedule.shouldCheck(lastCheck: nil, interval: 0, now: now))
    }

    // MARK: secondsUntilNextCheck

    func testSecondsUntilNextCheckCountsDownFromLast() {
        let last = now.addingTimeInterval(-1800)
        XCTAssertEqual(UpdateSchedule.secondsUntilNextCheck(lastCheck: last, interval: hour, now: now), 1800, accuracy: 0.001)
    }

    func testSecondsUntilNextCheckIsZeroWhenOverdue() {
        let last = now.addingTimeInterval(-7200)
        XCTAssertEqual(UpdateSchedule.secondsUntilNextCheck(lastCheck: last, interval: hour, now: now), 0, accuracy: 0.001)
    }

    func testDisabledIntervalIsInfinite() {
        XCTAssertEqual(UpdateSchedule.secondsUntilNextCheck(lastCheck: nil, interval: 0, now: now), .infinity)
    }

    // MARK: CheckInterval mapping

    func testCheckIntervalSeconds() {
        XCTAssertNil(CheckInterval.off.seconds)
        XCTAssertEqual(CheckInterval.hourly.seconds, 3600)
        XCTAssertEqual(CheckInterval.every6Hours.seconds, 21600)
        XCTAssertEqual(CheckInterval.daily.seconds, 86400)
        XCTAssertFalse(CheckInterval.off.isAutomatic)
        XCTAssertTrue(CheckInterval.daily.isAutomatic)
    }
}
