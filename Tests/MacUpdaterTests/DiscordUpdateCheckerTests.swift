import XCTest
@testable import MacUpdaterCore

final class DiscordUpdateCheckerTests: XCTestCase {
    func testParsesNameFromSquirrel200() {
        let json = Data(#"{"name":"0.0.966","pub_date":"2026-01-01","url":"https://x"}"#.utf8)
        XCTAssertEqual(DiscordUpdateParser.latestVersion(fromSquirrelJSON: json), "0.0.966")
    }
    func testEmptyBodyReturnsNil() {
        XCTAssertNil(DiscordUpdateParser.latestVersion(fromSquirrelJSON: Data()))
    }
    func testGarbageReturnsNil() {
        XCTAssertNil(DiscordUpdateParser.latestVersion(fromSquirrelJSON: Data("not json".utf8)))
    }
    func testChannelMapCoversThreeFlavors() {
        XCTAssertEqual(DiscordUpdateChecker.channelsByBundleID["com.hnc.Discord"], "stable")
        XCTAssertEqual(DiscordUpdateChecker.channelsByBundleID["com.hnc.DiscordPTB"], "ptb")
        XCTAssertEqual(DiscordUpdateChecker.channelsByBundleID["com.hnc.DiscordCanary"], "canary")
    }
}
