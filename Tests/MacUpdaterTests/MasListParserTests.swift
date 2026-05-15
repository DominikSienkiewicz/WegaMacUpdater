import XCTest
@testable import MacUpdaterCore

final class MasListParserTests: XCTestCase {
    func testParsesFixture() throws {
        let output = try fixtureString(named: "mas-list", extension: "txt")

        let apps = MasListParser().parse(output)

        XCTAssertEqual(apps.count, 3)
        XCTAssertEqual(apps[0].appStoreID, "1569813296")
        XCTAssertEqual(apps[0].name, "1Password for Safari")
        XCTAssertEqual(apps[0].version, "2.29.0")
        XCTAssertEqual(apps[1].appStoreID, "497799835")
        XCTAssertEqual(apps[1].name, "Xcode")
        XCTAssertEqual(apps[1].version, "16.1")
        XCTAssertEqual(apps[2].appStoreID, "409183694")
        XCTAssertEqual(apps[2].name, "Keynote")
        XCTAssertEqual(apps[2].version, "14.3")
    }

    func testIgnoresBlankLines() {
        let output = "\n1569813296  1Password for Safari (2.29.0)\n\n"
        let apps = MasListParser().parse(output)
        XCTAssertEqual(apps.count, 1)
    }

    func testIgnoresMalformedLines() {
        let output = "not a valid line\n1569813296  AppName (1.0)"
        let apps = MasListParser().parse(output)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].name, "AppName")
    }
}
