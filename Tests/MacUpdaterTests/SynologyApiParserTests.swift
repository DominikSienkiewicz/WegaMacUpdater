import XCTest
@testable import MacUpdaterCore

final class SynologyApiParserTests: XCTestCase {
    func testParsesLatestVersionFromChangeLogFixture() throws {
        let data = try fixtureData(named: "synology-drive-changelog", extension: "json")

        let latest = try XCTUnwrap(SynologyApiParser.latestRelease(from: data))

        XCTAssertEqual(latest.version, "4.0.3-17892")
        XCTAssertEqual(latest.build, 17892)
    }

    func testReturnsNilForBadPayload() {
        let data = Data(#"{"message":"Bad Parameter"}"#.utf8)
        XCTAssertNil(SynologyApiParser.latestRelease(from: data))
    }

    func testReturnsNilWhenVersionsArrayIsEmpty() {
        let data = Data(#"{"identify":"x","info":{"versions":{"":{"all_versions":[]}}}}"#.utf8)
        XCTAssertNil(SynologyApiParser.latestRelease(from: data))
    }

    func testParsesBuildFromVersionStringFormat() {
        XCTAssertEqual(SynologyApiParser.buildNumber(fromVersionString: "4.0.3-17892"), 17892)
        XCTAssertEqual(SynologyApiParser.buildNumber(fromVersionString: "3.5.0-16088"), 16088)
        XCTAssertNil(SynologyApiParser.buildNumber(fromVersionString: "4.0.3"))
        XCTAssertNil(SynologyApiParser.buildNumber(fromVersionString: ""))
    }
}
