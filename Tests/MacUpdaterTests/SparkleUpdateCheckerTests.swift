import Testing
import Foundation
@testable import MacUpdaterCore

/// `SparkleUpdateChecker` is the generic fallback for every non-brew app that exposes
/// a Sparkle feed, yet had no dedicated test (only the feed-override *map* was covered).
/// These tests cover the `AppcastParser` directly and the full `check(app:)` flow via
/// the injected feed-override + `HTTPClient` seams (no network, no filesystem).
@Suite("SparkleUpdateChecker")
struct SparkleUpdateCheckerTests {

    // MARK: - AppcastParser

    // Version carried as an attribute on <enclosure> — the common Sparkle shape.
    @Test func parserReadsShortVersionStringFromEnclosureAttribute() {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <enclosure url="https://example.com/App-1.1.0.dmg" sparkle:shortVersionString="1.1.0" sparkle:version="110"/>
                </item>
            </channel>
        </rss>
        """
        #expect(AppcastParser.parse(data: Data(xml.utf8)) == "1.1.0")
    }

    // Version carried as a child element instead of an attribute — the parser must
    // fall back to the element's character data (namespace-unaware).
    @Test func parserReadsShortVersionStringFromChildElement() {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
                </item>
            </channel>
        </rss>
        """
        #expect(AppcastParser.parse(data: Data(xml.utf8)) == "1.2.0")
    }

    @Test func parserReturnsNilForMalformedXML() {
        #expect(AppcastParser.parse(data: Data("not xml".utf8)) == nil)
    }

    @Test func parserReturnsNilWhenNoItems() {
        let xml = "<rss><channel><title>App</title></channel></rss>"
        #expect(AppcastParser.parse(data: Data(xml.utf8)) == nil)
    }

    // MARK: - AppcastParser item selection (MKT-02)

    private struct AppcastItemFixture {
        var version: String
        var channel: String?
        var description: String?
    }

    private func appcast(items: [AppcastItemFixture]) -> String {
        let body = items.map { item -> String in
            var lines = ["<item>"]
            if let channel = item.channel { lines.append("<sparkle:channel>\(channel)</sparkle:channel>") }
            if let description = item.description { lines.append("<description>\(description)</description>") }
            lines.append("<enclosure url=\"https://example.com/App-\(item.version).dmg\" sparkle:shortVersionString=\"\(item.version)\"/>")
            lines.append("</item>")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
        return """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
        \(body)
            </channel>
        </rss>
        """
    }

    /// Appcasts are conventionally newest-first, but nothing enforces it — ChatGPT's feed
    /// carries older builds with newer `pubDate`s, and `ChatGPTUpdateParser` already takes the
    /// maximum for exactly that reason. The generic parser stopped at the first versioned
    /// item, so a feed listing `1.0.0` first reported an installed `1.1.0` as current while
    /// `1.2.0` waited further down.
    ///
    /// Red before the fix: `"1.0.0"`.
    @Test func parserPicksTheHighestVersionWhenItemsAreNotNewestFirst() {
        let xml = appcast(items: [
            .init(version: "1.0.0"),
            .init(version: "1.2.0"),
            .init(version: "1.1.0"),
        ])
        #expect(AppcastParser.parse(data: Data(xml.utf8)) == "1.2.0")
    }

    /// The release notes shown for the update must belong to the item that was chosen, not
    /// to whichever item happened to come first.
    ///
    /// Red before the fix: `"old"`.
    @Test func parserKeepsTheReleaseNotesOfTheItemItPicked() {
        let xml = appcast(items: [
            .init(version: "1.0.0", description: "old"),
            .init(version: "1.2.0", description: "new"),
        ])
        #expect(AppcastParser.parseItem(data: Data(xml.utf8))?.descriptionHTML == "new")
    }

    /// Sparkle offers an item carrying `<sparkle:channel>` only to users who opted into that
    /// channel; the default channel is every item *without* one. Taking the maximum over all
    /// items would otherwise turn every beta feed into a phantom update for stable users — a
    /// new false positive replacing the old false negative.
    ///
    /// Red before the fix: `"2.0.0-beta"` — first item wins, channel ignored.
    @Test func parserIgnoresItemsOnANamedChannel() {
        let xml = appcast(items: [
            .init(version: "2.0.0-beta", channel: "beta"),
            .init(version: "1.5.0"),
        ])
        #expect(AppcastParser.parse(data: Data(xml.utf8)) == "1.5.0")
    }

    // MARK: - AppcastParser release notes (F1)

    // The `<description>` is frequently HTML wrapped in CDATA. The parser must hand
    // back the *raw* markup untouched — sanitizing/AttributedString conversion is a
    // UI concern, not the parser's.
    @Test func parserExtractsDescriptionFromCDATA() {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <enclosure url="https://example.com/App-1.1.0.dmg" sparkle:shortVersionString="1.1.0"/>
                    <description><![CDATA[<h1>What's new</h1><p>Fixed a crash.</p>]]></description>
                </item>
            </channel>
        </rss>
        """
        let item = AppcastParser.parseItem(data: Data(xml.utf8))
        #expect(item?.version == "1.1.0")
        #expect(item?.descriptionHTML == "<h1>What's new</h1><p>Fixed a crash.</p>")
    }

    // Plain (non-CDATA) text description is returned verbatim.
    @Test func parserExtractsPlainDescription() {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <enclosure url="https://example.com/App-1.1.0.dmg" sparkle:shortVersionString="1.1.0"/>
                    <description>Minor bug fixes.</description>
                </item>
            </channel>
        </rss>
        """
        #expect(AppcastParser.parseItem(data: Data(xml.utf8))?.descriptionHTML == "Minor bug fixes.")
    }

    // A separate release-notes page linked via <sparkle:releaseNotesLink>.
    @Test func parserExtractsReleaseNotesLink() {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <sparkle:releaseNotesLink>https://example.com/notes/1.1.0.html</sparkle:releaseNotesLink>
                    <enclosure url="https://example.com/App-1.1.0.dmg" sparkle:shortVersionString="1.1.0"/>
                </item>
            </channel>
        </rss>
        """
        let item = AppcastParser.parseItem(data: Data(xml.utf8))
        #expect(item?.version == "1.1.0")
        #expect(item?.releaseNotesLink == URL(string: "https://example.com/notes/1.1.0.html"))
    }

    // SEC-09: a plain-HTTP release-notes link is MITM-able → reject it, just like the
    // feed URL. Version still parses; only the insecure link is dropped.
    @Test func parserRejectsNonHTTPSReleaseNotesLink() {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <sparkle:releaseNotesLink>http://example.com/notes/1.1.0.html</sparkle:releaseNotesLink>
                    <enclosure url="https://example.com/App-1.1.0.dmg" sparkle:shortVersionString="1.1.0"/>
                </item>
            </channel>
        </rss>
        """
        let item = AppcastParser.parseItem(data: Data(xml.utf8))
        #expect(item?.version == "1.1.0")
        #expect(item?.releaseNotesLink == nil)
    }

    // MARK: - check(app:)

    private let overrideBundleID = "com.test.app"
    private let feedURL = "https://example.com/appcast.xml"

    private func app(bundleID: String?, version: String?, path: String = "/Applications/Test.app") -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: path),
            name: "Test",
            bundleIdentifier: bundleID,
            version: version,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
    }

    private func checker(_ client: HTTPClient) -> SparkleUpdateChecker {
        SparkleUpdateChecker(client: client, feedOverrides: [overrideBundleID: feedURL])
    }

    private func appcast(version: String) -> String {
        """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <enclosure url="https://example.com/App-\(version).dmg" sparkle:shortVersionString="\(version)"/>
                </item>
            </channel>
        </rss>
        """
    }

    @Test func outdatedWhenFeedVersionDiffersFromInstalled() async {
        let result = await checker(FakeHTTP.client(ok: appcast(version: "1.1.0")))
            .check(app: app(bundleID: overrideBundleID, version: "1.0.0"))

        guard case .outdated(let outdated) = result else {
            Issue.record("expected .outdated, got \(result)"); return
        }
        #expect(outdated.availableVersion == "1.1.0")
        #expect(outdated.installedVersion == "1.0.0")
        #expect(outdated.source == .sparkle)
    }

    @Test func upToDateWhenFeedMatchesInstalled() async {
        let result = await checker(FakeHTTP.client(ok: appcast(version: "1.1.0")))
            .check(app: app(bundleID: overrideBundleID, version: "1.1.0"))
        #expect(result == .upToDate)
    }

    // REL-10: an installed build ahead of the feed (beta channel, or a feed that lags
    // behind the shipped release) must never be reported as "update available" — that
    // is an offer to downgrade, not to update.
    @Test func upToDateWhenInstalledIsNewerThanFeed() async {
        let result = await checker(FakeHTTP.client(ok: appcast(version: "1.9.0")))
            .check(app: app(bundleID: overrideBundleID, version: "2.0.0"))
        #expect(result == .upToDate)
    }

    // REL-10: `CFBundleShortVersionString` often carries the build number ("7.0.0 (77593)")
    // while the appcast advertises the bare marketing version ("7.0.0"). The strings differ
    // but the versions do not, so this must not surface as an update.
    @Test func upToDateWhenInstalledCarriesBuildNumberAndFeedDoesNot() async {
        let result = await checker(FakeHTTP.client(ok: appcast(version: "7.0.0")))
            .check(app: app(bundleID: overrideBundleID, version: "7.0.0 (77593)"))
        #expect(result == .upToDate)
    }

    // No override, no plist on disk, no UserDefaults entry → the feed can't be
    // resolved, so the checker doesn't apply (and makes no request).
    @Test func notApplicableWhenNoFeedResolves() async {
        let checker = SparkleUpdateChecker(client: FakeHTTP.client(status: 500), feedOverrides: [:])
        let result = await checker.check(
            app: app(bundleID: "com.wega.tests.no-such-bundle", version: "1.0.0", path: "/nonexistent/Fake.app")
        )
        #expect(result == .notApplicable)
    }

    @Test func unavailableWhenServerErrors() async {
        let result = await checker(FakeHTTP.client(status: 500))
            .check(app: app(bundleID: overrideBundleID, version: "1.0.0"))
        #expect(result == .unavailable)
    }

    @Test func failedWhenAppcastUnparseable() async {
        let result = await checker(FakeHTTP.client(ok: "<<not an appcast>>"))
            .check(app: app(bundleID: overrideBundleID, version: "1.0.0"))
        #expect(result == .failed)
    }

    // MARK: - AppcastParser.parseResult

    private func feed(_ items: String) -> Data {
        Data("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        \(items)
        </channel></rss>
        """.utf8)
    }

    private func item(version: String, description: String? = nil, pubDate: String? = nil) -> String {
        """
        <item>
          <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
          \(pubDate.map { "<pubDate>\($0)</pubDate>" } ?? "")
          \(description.map { "<description><![CDATA[\($0)]]></description>" } ?? "")
        </item>
        """
    }

    @Test func historyKeepsEveryReleaseNewerThanTheInstalledOne() {
        let data = feed(
            item(version: "1.0.0", description: "<p>Old</p>")
            + item(version: "1.1.0", description: "<p>Middle</p>")
            + item(version: "1.2.0", description: "<p>New</p>")
        )

        let result = AppcastParser.parseResult(data: data, installedVersion: "1.0.0")

        #expect(result?.latest.version == "1.2.0")
        #expect(result?.history.notes.map(\.version) == ["1.2.0", "1.1.0"])
        #expect(result?.history.notes.first?.body == "New")
        #expect(result?.history.omitted == 0)
    }

    @Test func historyCapsAndReportsWhatItLeftOut() {
        let items = (1...12).map { item(version: "1.0.\($0)", description: "<p>Note \($0)</p>") }.joined()

        let result = AppcastParser.parseResult(data: feed(items), installedVersion: "1.0.0", limit: 10)

        #expect(result?.history.notes.count == 10)
        #expect(result?.history.notes.first?.version == "1.0.12")
        #expect(result?.history.omitted == 2)
    }

    @Test func historyReadsThePublicationDate() {
        let data = feed(item(version: "2.0.0", description: "<p>New</p>",
                             pubDate: "Mon, 20 Jul 2026 10:00:00 +0000"))

        let note = AppcastParser.parseResult(data: data, installedVersion: "1.0.0")?.history.notes.first

        #expect(note?.publishedAt != nil)
    }

    @Test func entriesWithNoDescriptionAreLeftOutRatherThanShownEmpty() {
        let data = feed(item(version: "1.1.0") + item(version: "1.2.0", description: "<p>New</p>"))

        let result = AppcastParser.parseResult(data: data, installedVersion: "1.0.0")

        #expect(result?.history.notes.map(\.version) == ["1.2.0"])
        #expect(result?.history.omitted == 0)
    }

    @Test func aFeedWithNoUsableItemIsNoResultAtAll() {
        #expect(AppcastParser.parseResult(data: Data("not xml".utf8), installedVersion: "1.0.0") == nil)
    }

    @Test func theCheckerHandsTheNotesOnRatherThanDroppingThem() async {
        // `checker(_:)`, `app(bundleID:version:)`, `overrideBundleID` and `FakeHTTP` are the
        // suite's existing helpers — see the "check(app:)" section of this file.
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
                      <description><![CDATA[<p>Old</p>]]></description></item>
                <item><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>
                      <description><![CDATA[<p>Fixes a crash</p>]]></description>
                      <sparkle:releaseNotesLink>https://example.com/notes</sparkle:releaseNotesLink></item>
            </channel>
        </rss>
        """

        let result = await checker(FakeHTTP.client(ok: xml))
            .check(app: app(bundleID: overrideBundleID, version: "1.0.0"))

        guard case .outdated(let outdated) = result else {
            Issue.record("expected .outdated, got \(result)"); return
        }
        #expect(outdated.releaseNotes?.history.notes.map(\.version) == ["2.0.0"])
        #expect(outdated.releaseNotes?.history.notes.first?.body == "Fixes a crash")
        #expect(outdated.releaseNotes?.link == URL(string: "https://example.com/notes"))
    }
}
