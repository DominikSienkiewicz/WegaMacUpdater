import XCTest
@testable import MacUpdaterCore

final class ChromeUpdateCheckerTests: XCTestCase {
    /// Stable on 2026-11-08 (`.../channels/stable/versions/all/releases?filter=endtime=none`):
    /// `158.0.8127.18` reached 0.5% of one rollout group while `157.0.8103.39` served all of
    /// another. Wega offered 158 from the plain version list, and Chrome itself said it was
    /// up to date on 157 — an update its own updater would not give.
    private let stagedStable = Data("""
    {"releases":[
      {"version":"156.0.8078.80","fraction":0.495,"fractionGroup":"200"},
      {"version":"157.0.8103.38","fraction":0.2475,"fractionGroup":"200"},
      {"version":"158.0.8127.18","fraction":0.005,"fractionGroup":"200"},
      {"version":"157.0.8103.39","fraction":1,"fractionGroup":"199"},
      {"version":"157.0.8103.39","fraction":0,"fractionGroup":"200"},
      {"version":"156.0.8078.75","fraction":0,"fractionGroup":"200"}
    ]}
    """.utf8)

    func testAStagedReleaseIsNotOfferedToAChromeItsUpdaterKeepsCurrent() throws {
        let offered = try XCTUnwrap(ChromeUpdateParser.versionServedToEveryone(fromReleasesJSON: stagedStable))
        XCTAssertEqual(offered, "156.0.8078.80")
        XCTAssertFalse(isUpgrade(installed: "157.0.8103.39", latest: offered))
        XCTAssertTrue(isUpgrade(installed: "155.0.7999.10", latest: offered))
    }

    func testAFullyServedReleaseIsOfferedRegardlessOfOrder() {
        let json = Data("""
        {"releases":[
          {"version":"146.0.7651.0","fraction":0,"fractionGroup":"2"},
          {"version":"146.0.7672.0","fraction":1,"fractionGroup":"2"}
        ]}
        """.utf8)
        XCTAssertEqual(ChromeUpdateParser.versionServedToEveryone(fromReleasesJSON: json), "146.0.7672.0")
    }

    func testNoServedReleaseReturnsNil() {
        for body in [#"{"releases":[]}"#, #"{"releases":[{"version":"146.0.7672.0","fraction":0}]}"#,
                     #"{"versions":[{"version":"146.0.7672.0"}]}"#, "nope"] {
            XCTAssertNil(ChromeUpdateParser.versionServedToEveryone(fromReleasesJSON: Data(body.utf8)), body)
        }
    }

    func testChannelMapCoversFourChannels() {
        XCTAssertEqual(ChromeUpdateChecker.channelsByBundleID["com.google.Chrome"], "stable")
        XCTAssertEqual(ChromeUpdateChecker.channelsByBundleID["com.google.Chrome.canary"], "canary")
    }
}
