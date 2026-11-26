import Foundation
import MacUpdaterCore
import XCTest
@testable import WegaMacUpdater

final class LargeUnusedInventoryTests: XCTestCase {
    func testFilterRequiresMoreThanOneDecimalGigabyteAndAtLeast90DaysSinceOpening() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        func matches(_ size: Int64?, opened: Date?) -> Bool {
            InventoryAppActivity(lastOpenedAt: opened, protection: nil).isLargeAndUnused(bytes: size, now: now)
        }
        XCTAssertTrue(matches(1_000_000_001, opened: cutoff))
        XCTAssertTrue(matches(2_000_000_000, opened: cutoff.addingTimeInterval(-1)))
        XCTAssertFalse(matches(1_000_000_000, opened: cutoff))
        XCTAssertFalse(matches(1_000_000_001, opened: cutoff.addingTimeInterval(1)))
        XCTAssertFalse(matches(1_000_000_001, opened: now.addingTimeInterval(1)))
        XCTAssertFalse(matches(1_000_000_001, opened: nil))
        XCTAssertFalse(matches(nil, opened: cutoff))
    }
}

extension LargeUnusedInventoryTests {
    func testCopiesHaveTheirOwnOpeningDatesAndOnlyTheReviewedPathIsPreselected() throws {
        let recent = Date(timeIntervalSince1970: 1_780_000_000)
        let old = recent.addingTimeInterval(-120 * 86400)
        let first = application("/Applications/Fixture.app", modified: recent)
        let second = application("/Users/fixture/Applications/Fixture.app", modified: old)
        let protected = application("/System/Applications/Protected.app", modified: old)
        let unknown = application("/Applications/Unindexed.app", modified: old)
        let apps = [first, second, protected, unknown]
        let protections = [protected.id: UninstallProtection.systemApplication]
        let opened = [first.path: old, second.path: recent, protected.path: old]
        let activity = InventoryAppActivity.read(apps: apps, protections: protections, lastOpened: { opened[$0] })
        XCTAssertEqual(activity[first.installation]?.lastOpenedAt, old)
        XCTAssertEqual(activity[second.installation]?.lastOpenedAt, recent)
        let missing = try XCTUnwrap(activity[unknown.installation])
        XCTAssertNil(missing.lastOpenedAt, "An old modification date cannot fill in a missing opening date")
        XCTAssertFalse(missing.isLargeAndUnused(bytes: 2_000_000_000, now: recent))
        XCTAssertNil(activity[protected.installation]?.uninstallReviewTarget(for: protected))
        let target = try XCTUnwrap(activity[second.installation]?.uninstallReviewTarget(for: second))
        XCTAssertEqual(UninstallSelection.duplicateGroup(for: target, in: [first, second]), "test.fixture")
        XCTAssertNil(UninstallSelection.duplicateGroup(for: target, in: [first]))
        XCTAssertEqual(UninstallSelection.preselection(for: target, in: apps, protections: protections), [second.id])
    }

    private func application(_ path: String, modified: Date) -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: path), name: "Fixture", bundleIdentifier: "test.fixture", version: "1",
                        installDate: modified, updateDate: modified, isManagedByBrew: false)
    }
}
