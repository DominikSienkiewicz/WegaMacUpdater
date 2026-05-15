import XCTest
@testable import MacUpdaterCore

final class MasOutdatedParserTests: XCTestCase {
    func testParsesMasOutdatedFixture() throws {
        let output = try fixtureString(named: "mas-outdated", extension: "txt")

        let apps = MasOutdatedParser().parse(output)

        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].appStoreID, "1569813296")
        XCTAssertEqual(apps[0].name, "1Password for Safari")
        XCTAssertEqual(apps[0].installedVersion, "2.29.0")
        XCTAssertEqual(apps[0].currentVersion, "2.30.0")
        XCTAssertEqual(apps[1].name, "Xcode")
    }
}
