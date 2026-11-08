import Testing
import Foundation
@testable import MacUpdaterCore

/// On 2026-11-08 ChatGPT (`com.openai.codex`) said it was up to date on 26.1103.41825 while
/// Wega offered 26.1103.60933. OpenAI's static appcast lists a release as soon as the first
/// rollout group gets it. The app itself asks `updates.oaistatic.com/codex/app/appcast`, which
/// redirected 10 of 12 sampled installations, and 40 of 40 sampled without a known plan, to
/// the appcast that ends at 26.1103.41825.
@Suite("ChatGPT staged rollout")
struct ChatGPTStagedRolloutTests {
    private static let staticFeed = "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"

    private static let expectedArchitecture: String = {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }()

    private let chatGPT = ApplicationInfo(
        path: URL(fileURLWithPath: "/Applications/ChatGPT.app"), name: "ChatGPT",
        bundleIdentifier: "com.openai.codex", version: "26.1103.41825", buildVersion: "25679",
        installDate: nil, updateDate: nil, isManagedByBrew: false, caskToken: "chatgpt"
    )

    private static func appcast(_ releases: [(version: String, build: String)]) -> String {
        let items = releases.map { release in
            """
            <item>
                <title>\(release.version)</title>
                <sparkle:version>\(release.build)</sparkle:version>
                <sparkle:shortVersionString>\(release.version)</sparkle:shortVersionString>
                <enclosure url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-\(release.version).zip" type="application/octet-stream"/>
            </item>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel><title>Codex</title>
        \(items)
            </channel>
        </rss>
        """
    }

    /// Everything OpenAI has published, including the release still rolling out.
    private static let published = appcast([("26.1103.60933", "25894"), ("26.1103.41825", "25679"), ("26.1103.32239", "25471")])
    /// What the rollout endpoint redirects an installation to while 26.1103.60933 rolls out.
    private static let servedDuringRollout = appcast([("26.1103.41825", "25679"), ("26.1103.32239", "25471")])
    /// What the rollout endpoint redirects to once 26.1103.60933 reaches everyone.
    private static let servedAfterRollout = published

    /// Answers like URLSession after following the rollout endpoint's redirect: the body of
    /// the appcast that endpoint points at, or the static feed for any other URL.
    private struct OpenAITransport: HTTPTransport {
        let served: String

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badURL) }
            let body = url.host == "updates.oaistatic.com" ? served : ChatGPTStagedRolloutTests.published
            return (Data(body.utf8), response)
        }
    }

    private func checker(served: String) -> SparkleUpdateChecker {
        SparkleUpdateChecker(
            client: HTTPClient(transport: OpenAITransport(served: served), maxRetries: 0, retryBaseDelay: 0),
            feedOverrides: ["com.openai.codex": Self.staticFeed]
        )
    }

    @Test func aReleaseStillRollingOutIsNotOffered() async {
        let result = await checker(served: Self.servedDuringRollout).check(app: chatGPT)
        #expect(result == .upToDate)
    }

    @Test func aReleaseServedToEveryoneIsOffered() async {
        let result = await checker(served: Self.servedAfterRollout).check(app: chatGPT)
        guard case .outdated(let update) = result else {
            Issue.record("expected .outdated, got \(result)"); return
        }
        #expect(update.availableVersion == "26.1103.60933 (25894)")
    }

    @Test func asksTheRolloutEndpointAsAnInstallationWithNoKnownPlanOrIdentity() throws {
        let url = try #require(checker(served: Self.servedDuringRollout).plan(for: chatGPT)?.request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.scheme == "https")
        #expect(components.host == "updates.oaistatic.com")
        #expect(components.path == "/codex/app/appcast")
        #expect(query == [
            "installation_id": "00000000-0000-0000-0000-000000000000",
            "arch": Self.expectedArchitecture,
            "app_version": "26.1103.41825",
            "beta": "false",
            "plan_type": "unknown",
        ])
    }

    @Test func anotherAppKeepsItsOwnFeed() throws {
        let other = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Other.app"), name: "Other",
            bundleIdentifier: "com.example.other", version: "1.0", installDate: nil, updateDate: nil, isManagedByBrew: false
        )
        let checker = SparkleUpdateChecker(client: FakeHTTP.client(ok: ""), feedOverrides: ["com.example.other": "https://example.com/appcast.xml"])
        #expect(checker.plan(for: other)?.request.url.absoluteString == "https://example.com/appcast.xml")
    }
}
