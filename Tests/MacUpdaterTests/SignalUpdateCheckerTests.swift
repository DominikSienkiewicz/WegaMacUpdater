import XCTest
@testable import MacUpdaterCore

final class SignalUpdateCheckerTests: XCTestCase {
    func testParsesVersionFromYAML() {
        let yaml = Data("""
        version: 7.68.0
        files:
          - url: signal-desktop-mac-arm64-7.68.0.zip
            sha512: abc
        releaseDate: '2026-01-01T00:00:00.000Z'
        """.utf8)
        XCTAssertEqual(SignalUpdateParser.latestVersion(fromYAML: yaml), "7.68.0")
    }
    func testQuotedVersionStripped() {
        XCTAssertEqual(SignalUpdateParser.latestVersion(fromYAML: Data("version: '7.70.1'\n".utf8)), "7.70.1")
    }
    func testMissingVersionReturnsNil() {
        XCTAssertNil(SignalUpdateParser.latestVersion(fromYAML: Data("files: []\n".utf8)))
    }
}
