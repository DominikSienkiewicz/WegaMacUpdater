import XCTest
@testable import MacUpdaterCore

final class MasSearchParserTests: XCTestCase {
    private let parser = MasSearchParser()

    func testParsesFixture() throws {
        let output = try fixtureString(named: "mas-search", extension: "txt")
        let results = parser.parse(output)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].appStoreID, "324684580")
        XCTAssertEqual(results[0].name, "Spotify - Music and Podcasts")
        XCTAssertEqual(results[1].appStoreID, "497799835")
        XCTAssertEqual(results[1].name, "Xcode")
        XCTAssertEqual(results[2].appStoreID, "409183694")
        XCTAssertEqual(results[2].name, "Keynote")
    }

    func testIgnoresBlankLines() {
        let output = "\n  324684580  Spotify - Music and Podcasts             1.2.13\n\n"
        let results = parser.parse(output)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].appStoreID, "324684580")
    }

    func testIgnoresMalformedLines() {
        let output = "not a valid line\n  324684580  Spotify - Music and Podcasts             1.2.13"
        let results = parser.parse(output)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].appStoreID, "324684580")
    }

    func testReturnsEmptyForEmptyInput() {
        XCTAssertTrue(parser.parse("").isEmpty)
    }
}
