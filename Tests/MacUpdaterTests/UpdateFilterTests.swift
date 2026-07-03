import XCTest
@testable import MacUpdaterCore

final class UpdateFilterTests: XCTestCase {
    func testAllAllowsEverythingAndIsNotSecurityOnly() {
        let filter = UpdateFilter.all
        XCTAssertTrue(filter.allowsApps)
        XCTAssertTrue(filter.allowsCli)
        XCTAssertFalse(filter.isSecurityOnly)
    }

    func testAppsAllowsOnlyApps() {
        let filter = UpdateFilter.apps
        XCTAssertTrue(filter.allowsApps)
        XCTAssertFalse(filter.allowsCli)
        XCTAssertFalse(filter.isSecurityOnly)
    }

    func testCliAllowsOnlyCli() {
        let filter = UpdateFilter.cli
        XCTAssertFalse(filter.allowsApps)
        XCTAssertTrue(filter.allowsCli)
        XCTAssertFalse(filter.isSecurityOnly)
    }

    func testSecurityIsSecurityOnlyAndAllowsNeither() {
        let filter = UpdateFilter.security
        XCTAssertFalse(filter.allowsApps)
        XCTAssertFalse(filter.allowsCli)
        XCTAssertTrue(filter.isSecurityOnly)
    }
}
