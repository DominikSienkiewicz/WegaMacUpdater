import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Sparkle does not compare display versions against builds")
struct SparkleUncomparableVersionsTests {
    @Test func buildOnlyFeedWithoutLocalBuildIsUnconfirmed() async {
        for local in ["1.0", "100", "200"] {
            let result = await checker.check(app: app(version: local))
            #expect(result == .failed)
        }
    }

    @Test func buildOnlyEntriesCannotLeakIntoDisplayVersionHistory() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>999</sparkle:version><description>Build only</description></item>
        <item><sparkle:shortVersionString>2.0</sparkle:shortVersionString><description>Display</description></item>
        </channel></rss>
        """
        let result = AppcastParser.parseResult(data: Data(xml.utf8), installedVersion: "1.0")
        #expect(result?.latest.version == "2.0")
        #expect(result?.history.notes.map(\.version) == ["2.0"])
    }

    @Test func buildOnlyFeedStillWorksWhenBothSidesHaveBuilds() async {
        var installed = app(version: "1.0")
        installed.buildVersion = "100"
        guard case .outdated(let row) = await checker.check(app: installed) else {
            Issue.record("Comparable builds must remain supported"); return
        }
        #expect(row.availableVersion == "101")
    }

    private var checker: SparkleUpdateChecker {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>101</sparkle:version></item></channel></rss>
        """
        return SparkleUpdateChecker(client: FakeHTTP.client(ok: xml), feedOverrides: ["com.example.missing-build": "https://example.invalid/feed"])
    }

    private func app(version: String) -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                        bundleIdentifier: "com.example.missing-build", version: version,
                        installDate: nil, updateDate: nil, isManagedByBrew: false)
    }
}
