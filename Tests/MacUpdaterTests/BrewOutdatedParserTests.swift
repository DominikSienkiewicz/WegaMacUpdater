import XCTest
@testable import MacUpdaterCore

final class BrewOutdatedParserTests: XCTestCase {
    func testParsesOutdatedV2Fixture() throws {
        let data = try fixtureData(named: "brew-outdated-v2", extension: "json")

        let result = try BrewOutdatedParser().parse(data)

        XCTAssertEqual(result.formulae.map(\.name), ["git", "node"])
        XCTAssertEqual(result.formulae[0].installedVersions, ["2.45.0"])
        XCTAssertEqual(result.formulae[1].installedVersions, ["24.0.0"])
        XCTAssertEqual(result.casks.map(\.name), ["visual-studio-code", "postman"])
        XCTAssertEqual(result.casks[0].currentVersion, "1.91.0")
        XCTAssertEqual(result.casks[0].autoUpdates, true)
        XCTAssertEqual(result.totalCount, 4)
    }
}
