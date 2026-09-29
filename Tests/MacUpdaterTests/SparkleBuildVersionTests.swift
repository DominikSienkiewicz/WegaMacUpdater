import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Sparkle compares CFBundleVersion, not the display version")
struct SparkleBuildVersionTests {
    @Test func sameDisplayVersionWithANewerBuildIsAnUpdate() async throws {
        let result = await check(items: item(build: "101", display: "1.0"), installed: "1.0", build: "100")
        guard case .outdated(let app) = result else { Issue.record("The newer build was hidden"); return }
        #expect(app.installedVersion == "1.0 (100)")
        #expect(app.availableVersion == "1.0 (101)")
    }

    @Test func aHigherDisplayVersionCannotOfferAnOlderBuild() async {
        #expect(await check(items: item(build: "99", display: "2.0"), installed: "1.0", build: "100") == .upToDate)
    }

    @Test func everyDottedBuildComponentParticipatesInOrdering() async {
        let result = await check(items: item(build: "100.1.2.1", display: "1.0"), installed: "1.0", build: "100.1.2")
        guard case .outdated = result else { Issue.record("The fourth build component must not be discarded"); return }
    }

    @Test func elementsAndAttributesHaveTheSameMeaningAndElementsTakePrecedence() async {
        let element = """
        <item><sparkle:version>101</sparkle:version><sparkle:shortVersionString>1.0</sparkle:shortVersionString>
        <enclosure sparkle:version="99" sparkle:shortVersionString="0.9"/></item>
        """
        let attribute = item(build: "101", display: "1.0")
        let fromElement = await check(items: element, installed: "1.0", build: "100")
        let fromAttribute = await check(items: attribute, installed: "1.0", build: "100")
        #expect(fromElement == fromAttribute)
    }

    @Test func buildOnlyElementWorksWithoutADisplayVersion() async {
        let result = await check(items: "<item><sparkle:version>101</sparkle:version></item>", installed: "100", build: "100")
        guard case .outdated(let app) = result else { Issue.record("A valid build element was dropped"); return }
        #expect(app.availableVersion == "101")
    }

    @Test func historyRetainsDistinctBuildsOfTheSameReleaseInBuildOrder() async {
        let result = await check(
            items: item(build: "101", display: "1.0", notes: "First") + item(build: "102", display: "1.0", notes: "Second"),
            installed: "1.0", build: "100"
        )
        guard case .outdated(let app) = result else { Issue.record("Expected two newer builds"); return }
        #expect(app.releaseNotes?.history.notes.map(\.version) == ["1.0 (102)", "1.0 (101)"])
        #expect(app.releaseNotes?.history.notes.map(\.id) == ["1.0 (102)", "1.0 (101)"])
    }

    @Test func missingLocalBuildUsesOnlyComparableDisplayVersions() async {
        let newer = await check(items: item(build: "10000", display: "1.1"), installed: "1.0", build: nil)
        guard case .outdated(let app) = newer else { Issue.record("A newer display version remains comparable"); return }
        #expect(app.availableVersion == "1.1")
        #expect(await check(items: item(build: "10000", display: "1.0"), installed: "1.0", build: nil) == .upToDate)
    }

    @Test func unparseableBuildCannotClaimTheAppIsCurrent() async {
        #expect(await check(items: item(build: "unknown", display: "1.1"), installed: "1.0", build: "100") == .failed)
    }

    @Test func chatGPTUsesTheSameBuildSemantics() async {
        let checker = ChatGPTUpdateChecker(client: FakeHTTP.client(ok: feed(item(build: "101", display: "1.0"))))
        let result = await checker.check(app: app(installed: "1.0", build: "100", bundleID: ChatGPTUpdateChecker.bundleIdentifier))
        guard case .outdated(let update) = result else { Issue.record("The dedicated checker must also detect newer builds"); return }
        #expect(update.availableVersion == "1.0 (101)")
        #expect(update.source == .chatgpt)
    }

    private func check(items: String, installed: String, build: String?) async -> ManualCheckResult {
        await SparkleUpdateChecker(
            client: FakeHTTP.client(ok: feed(items)), feedOverrides: ["com.example.sparkle": "https://example.invalid/feed.xml"]
        ).check(app: app(installed: installed, build: build))
    }

    private func app(installed: String, build: String?, bundleID: String = "com.example.sparkle") -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                        bundleIdentifier: bundleID, version: installed, buildVersion: build,
                        installDate: nil, updateDate: nil, isManagedByBrew: false)
    }

    private func item(build: String, display: String, notes: String = "") -> String {
        "<item><enclosure sparkle:version=\"\(build)\" sparkle:shortVersionString=\"\(display)\"/><description>\(notes)</description></item>"
    }

    private func feed(_ items: String) -> String {
        "<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>\(items)</channel></rss>"
    }
}
