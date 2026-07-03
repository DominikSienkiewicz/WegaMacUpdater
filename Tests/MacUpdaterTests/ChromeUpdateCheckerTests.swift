import XCTest
@testable import MacUpdaterCore

final class ChromeUpdateCheckerTests: XCTestCase {
    func testPicksNewestVersionRegardlessOfOrder() {
        let json = Data("""
        {"versions":[
          {"version":"146.0.7651.0"},
          {"version":"146.0.7672.0"},
          {"version":"146.0.7600.1"}
        ]}
        """.utf8)
        XCTAssertEqual(ChromeUpdateParser.newestVersion(fromVersionHistoryJSON: json), "146.0.7672.0")
    }
    func testEmptyVersionsReturnsNil() {
        XCTAssertNil(ChromeUpdateParser.newestVersion(fromVersionHistoryJSON: Data(#"{"versions":[]}"#.utf8)))
    }
    func testGarbageReturnsNil() {
        XCTAssertNil(ChromeUpdateParser.newestVersion(fromVersionHistoryJSON: Data("nope".utf8)))
    }
    func testChannelMapCoversFourChannels() {
        XCTAssertEqual(ChromeUpdateChecker.channelsByBundleID["com.google.Chrome"], "stable")
        XCTAssertEqual(ChromeUpdateChecker.channelsByBundleID["com.google.Chrome.canary"], "canary")
    }
}
