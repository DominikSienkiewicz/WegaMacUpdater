import XCTest
@testable import MacUpdaterCore

final class SparkleFeedOverridesTests: XCTestCase {
    /// Reproduces the bug where Codex.app was not seen as outdated because Sparkle's
    /// SUFeedURL is configured at runtime, not via Info.plist. The override map closes that gap.
    func testCodexAppHasFeedOverride() {
        let url = SparkleFeedOverrides.defaults["com.openai.codex"]
        XCTAssertEqual(url, "https://persistent.oaistatic.com/codex-app-prod/appcast.xml")
    }

    func testParserPicksUpFirstShortVersionFromRealCodexAppcast() throws {
        let data = try fixtureData(named: "sparkle-appcast-codex", extension: "xml")
        let latest = AppcastParser.parse(data: data)
        XCTAssertEqual(latest, "26.513.31313")
    }
}
