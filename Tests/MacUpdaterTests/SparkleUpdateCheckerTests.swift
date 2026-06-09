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
}
