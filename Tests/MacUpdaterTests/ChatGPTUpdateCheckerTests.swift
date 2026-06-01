import XCTest
@testable import MacUpdaterCore

final class ChatGPTUpdateCheckerTests: XCTestCase {

    // Trimmed real payload from
    // https://persistent.oaistatic.com/sidekick/public/sparkle_public_appcast.xml
    // captured 2026-06-01. Note: 1.2026.118 carries a LATER pubDate (11:46:19)
    // than the newer 1.2026.119 (11:46:07), exactly the "older items have a more
    // recent pubDate" quirk Homebrew's cask warns about. The parser must pick
    // the max shortVersionString across all items, never the first/newest-dated.
    private let sampleXML = """
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
        <channel>
            <title>ChatGPT</title>
            <item>
                <title>1.2026.119</title>
                <pubDate>Fri, 29 May 2026 11:46:07 +0000</pubDate>
                <sparkle:version>1780053722</sparkle:version>
                <sparkle:shortVersionString>1.2026.119</sparkle:shortVersionString>
                <enclosure url="https://persistent.oaistatic.com/sidekick/public/ChatGPT_Desktop_public_1.2026.119_1780053722.dmg" length="72644134" type="application/octet-stream"/>
            </item>
            <item>
                <title>1.2026.118</title>
                <pubDate>Fri, 29 May 2026 11:46:19 +0000</pubDate>
                <sparkle:version>1777682760</sparkle:version>
                <sparkle:shortVersionString>1.2026.118</sparkle:shortVersionString>
                <enclosure url="https://persistent.oaistatic.com/sidekick/public/ChatGPT_Desktop_public_1.2026.118_1777682760.dmg" length="71922722" type="application/octet-stream"/>
            </item>
            <item>
                <title>1.2026.104</title>
                <pubDate>Fri, 29 May 2026 11:46:17 +0000</pubDate>
                <sparkle:version>1776709323</sparkle:version>
                <sparkle:shortVersionString>1.2026.104</sparkle:shortVersionString>
                <enclosure url="https://persistent.oaistatic.com/sidekick/public/ChatGPT_Desktop_public_1.2026.104_1776709323.dmg" length="63238742" type="application/octet-stream"/>
            </item>
        </channel>
    </rss>
    """

    // Same items, reordered so the newest version (119) is NOT first. Proves the
    // parser scans every item and compares, rather than trusting document order.
    private let reorderedXML = """
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
        <channel>
            <title>ChatGPT</title>
            <item>
                <sparkle:shortVersionString>1.2026.118</sparkle:shortVersionString>
            </item>
            <item>
                <sparkle:shortVersionString>1.2026.119</sparkle:shortVersionString>
            </item>
            <item>
                <sparkle:shortVersionString>1.2026.104</sparkle:shortVersionString>
            </item>
        </channel>
    </rss>
    """

    func testLatestVersionPicksMaxAcrossAllItems() {
        XCTAssertEqual(ChatGPTUpdateParser.latestVersion(fromAppcast: Data(sampleXML.utf8)), "1.2026.119")
    }

    // Regression for the reported bug: brew/Sparkle both report 1.2026.118 yet
    // 1.2026.119 is live in the public feed. The parser must surface 119 even
    // though 118 has the most recent pubDate and would win a "first item" parse.
    func testLatestVersionIgnoresPubDateOrdering() {
        let latest = ChatGPTUpdateParser.latestVersion(fromAppcast: Data(reorderedXML.utf8))
        XCTAssertEqual(latest, "1.2026.119")
    }

    func testReportedInstalledIsDetectedAsOutdatedAgainstLatest() {
        let latest = ChatGPTUpdateParser.latestVersion(fromAppcast: Data(sampleXML.utf8))!
        // Real reproduction: installed 1.2026.118, feed offers 1.2026.119,
        // while Homebrew cask `chatgpt` (auto_updates) still reports 1.2026.118.
        XCTAssertTrue(isUpgrade(installed: "1.2026.118", latest: latest))
    }

    func testLatestVersionReturnsNilForMalformedXML() {
        XCTAssertNil(ChatGPTUpdateParser.latestVersion(fromAppcast: Data("not xml".utf8)))
    }

    func testLatestVersionReturnsNilWhenNoItems() {
        let xml = "<rss><channel><title>ChatGPT</title></channel></rss>"
        XCTAssertNil(ChatGPTUpdateParser.latestVersion(fromAppcast: Data(xml.utf8)))
    }

    func testCheckerTargetsChatGPTBundleIdentifier() {
        XCTAssertEqual(ChatGPTUpdateChecker.bundleIdentifier, "com.openai.chat")
    }

    func testCheckerUsesPublicSidekickAppcast() {
        XCTAssertEqual(ChatGPTUpdateChecker.appcastURL.absoluteString,
                       "https://persistent.oaistatic.com/sidekick/public/sparkle_public_appcast.xml")
    }
}
