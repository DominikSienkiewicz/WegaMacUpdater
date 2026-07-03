import XCTest
@testable import MacUpdaterCore

final class UpdateCategoryTests: XCTestCase {
    func testFormulaIsCliCategory() {
        XCTAssertEqual(OutdatedItem.Kind.formula.category, .cli)
    }

    func testCaskIsAppsCategory() {
        XCTAssertEqual(OutdatedItem.Kind.cask.category, .apps)
    }

    func testAppStoreIsAppsCategory() {
        XCTAssertEqual(OutdatedItem.Kind.appStore.category, .apps)
    }

    func testNpmIsCliCategory() {
        XCTAssertEqual(OutdatedItem.Kind.npm.category, .cli)
    }
}
