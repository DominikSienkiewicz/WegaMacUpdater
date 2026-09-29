import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Cask notes are independent of duplicate-update suppression")
struct CaskReleaseNotesTests {
    @Test func anOutdatedCaskCanFetchTheExactReleaseWithoutAddingAnotherUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.example.notes", "CFBundleShortVersionString": "1.0",
                     "CFBundleVersion": "100", "SUFeedURL": "https://example.invalid/feed.xml"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Contents/Info.plist"))
        let app = ApplicationInfo(path: path, name: "Example", bundleIdentifier: "com.example.notes", version: "1.0",
                                  installDate: nil, updateDate: nil, isManagedByBrew: true, caskToken: "example")
        let routed = ManualUpdateScanner.routeDistinctInstallations(
            [app], caskAppPaths: ["example": path], brewOutdatedCasks: ["example"]
        )
        #expect(routed.isEmpty)
        let item = OutdatedItem(key: "c:example", name: "example", from: "1.0,100", to: "1.0,101", kind: .cask)
        let request = try #require(CaskReleaseNotesRequest(item: item, appPath: path))
        let provider = CaskReleaseNotesProvider(
            sparkle: SparkleUpdateChecker(client: FakeHTTP.client(ok: Self.feed), feedOverrides: [:]),
            github: GitHubReleasesChecker(repos: [:])
        )
        guard case .notes(let notes) = await provider.notes(for: request) else {
            Issue.record("An outdated cask must still have a reachable notes path")
            return
        }
        #expect(notes.history.notes.map(\.version) == ["1.0 (101)"])
        #expect(notes.plainText == "Build 101 changes")
        #expect(item.releaseNotes == nil)
    }

    @Test func buildIdentityPreventsNotesForAnotherRelease() {
        #expect(AppcastParser.releaseNotes(data: Data(Self.feed.utf8), targetVersion: "1.0") == nil)
        #expect(AppcastParser.releaseNotes(data: Data(Self.feed.utf8), targetVersion: "1.0,999") == nil)
        #expect(AppcastParser.releaseNotes(data: Data(Self.feed.utf8), targetVersion: "1.0 (101)")?.plainText == "Build 101 changes")
        #expect(AppcastParser.releaseNotes(data: Data(Self.feed.utf8), targetVersion: "2.0,200")?.plainText == "Future changes")
        #expect(AppcastParser.releaseNotes(data: Data("<broken".utf8), targetVersion: "1.0") == nil)
    }

    @Test func notesRequireACaskWithAKnownTargetAndAnExactBundlePath() {
        let formula = OutdatedItem(key: "f:example", name: "example", from: "1", to: "2", kind: .formula)
        #expect(CaskReleaseNotesRequest(item: formula, appPath: URL(fileURLWithPath: "/Applications/Example.app")) == nil)
        let cask = OutdatedItem(key: "c:example", name: "example", from: "1", to: nil, kind: .cask)
        #expect(CaskReleaseNotesRequest(item: cask, appPath: nil) == nil)
    }

    @Test func githubNotesUseTheOfferedTagEvenIfANewerReleaseExists() async throws {
        let fixture = try NotesFixture(feed: nil, target: "2.0")
        defer { fixture.remove() }
        let json = """
        [{"tag_name":"v3.0","draft":false,"prerelease":false,"body":"Future"},
         {"tag_name":"v2.0","draft":false,"prerelease":false,"body":"Offered"},
         {"tag_name":"v2.1-beta","draft":false,"prerelease":true,"body":"Beta"}]
        """
        let provider = CaskReleaseNotesProvider(
            sparkle: SparkleUpdateChecker(feedOverrides: [:]),
            github: GitHubReleasesChecker(client: FakeHTTP.client(ok: json), repos: [
                "com.example.notes": GitHubCatalogEntry(bundleId: "com.example.notes", repo: "example/notes", caskToken: "example")
            ])
        )
        #expect(await provider.notes(for: fixture.request) == .notes(ReleaseNotes(html: "Offered", version: "2.0")))
    }

    @Test func transportAndMalformedFeedsAllowRetryWhileMissingNotesAreUnavailable() async throws {
        let fixture = try NotesFixture(feed: "https://example.invalid/feed.xml", target: "1.0,101")
        defer { fixture.remove() }
        for client in [FakeHTTP.client(status: 503), FakeHTTP.client(ok: "<broken")] {
            let provider = CaskReleaseNotesProvider(sparkle: SparkleUpdateChecker(client: client, feedOverrides: [:]),
                                                    github: GitHubReleasesChecker(repos: [:]))
            #expect(await provider.notes(for: fixture.request) == .failed)
        }
        let provider = CaskReleaseNotesProvider(
            sparkle: SparkleUpdateChecker(client: FakeHTTP.client(ok: "<rss><channel/></rss>"), feedOverrides: [:]),
            github: GitHubReleasesChecker(repos: [:])
        )
        #expect(await provider.notes(for: fixture.request) == .unavailable)
    }

    static let feed = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <item><sparkle:version>100</sparkle:version><sparkle:shortVersionString>1.0</sparkle:shortVersionString><description>Old changes</description></item>
    <item><sparkle:version>101</sparkle:version><sparkle:shortVersionString>1.0</sparkle:shortVersionString><description>Build 101 changes</description></item>
    <item><sparkle:version>200</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString><description>Future changes</description></item>
    </channel></rss>
    """
}

private struct NotesFixture {
    let root: URL
    let request: CaskReleaseNotesRequest

    init(feed: String?, target: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var plist = ["CFBundleIdentifier": "com.example.notes", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "100"]
        plist["SUFeedURL"] = feed
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        request = CaskReleaseNotesRequest(
            item: OutdatedItem(key: "c:example", name: "example", from: "1.0", to: target, kind: .cask), appPath: app
        )!
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
