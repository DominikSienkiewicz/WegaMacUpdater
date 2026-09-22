import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("GitHubReleaseHistory")
struct GitHubReleaseHistoryTests {

    private func release(
        tag: String,
        body: String = "notes",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> String {
        """
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),
         "body":"\(body)","published_at":"2026-07-20T10:00:00Z"}
        """
    }

    private func data(_ releases: [String]) -> Data {
        Data("[\(releases.joined(separator: ","))]".utf8)
    }

    @Test func dropsDraftsAndPrereleases() throws {
        let releases = try #require(GitHubReleaseHistory.stableReleases(from: data([
            release(tag: "v2.0.0-rc1", prerelease: true),
            release(tag: "v1.9.0", draft: true),
            release(tag: "v1.8.0"),
        ])))

        #expect(releases.map(\.tagName) == ["v1.8.0"])
    }

    @Test func malformedJsonIsNoAnswerRatherThanAnEmptyOne() {
        #expect(GitHubReleaseHistory.stableReleases(from: Data("nope".utf8)) == nil)
    }

    @Test func newestIsTheHighestTagNotTheFirstRow() throws {
        let releases = try #require(GitHubReleaseHistory.stableReleases(from: data([
            release(tag: "v1.8.0"),
            release(tag: "v1.10.0"),
            release(tag: "v1.9.0"),
        ])))

        #expect(GitHubReleaseHistory.newest(releases)?.tagName == "v1.10.0")
    }

    @Test func historyKeepsOnlyWhatTheUserHasNotGot() throws {
        let releases = try #require(GitHubReleaseHistory.stableReleases(from: data([
            release(tag: "v1.2.0", body: "Newest"),
            release(tag: "v1.1.0", body: "Middle"),
            release(tag: "v1.0.0", body: "Oldest"),
        ])))

        let history = GitHubReleaseHistory.history(releases, newerThan: "1.0.0", limit: 10)

        #expect(history.notes.map(\.version) == ["1.2.0", "1.1.0"])
        #expect(history.notes.first?.body == "Newest")
        #expect(history.omitted == 0)
    }

    @Test func historyCapsAndCountsTheRest() throws {
        let releases = try #require(GitHubReleaseHistory.stableReleases(
            from: data((1...12).map { release(tag: "v1.0.\($0)") })
        ))

        let history = GitHubReleaseHistory.history(releases, newerThan: "1.0.0", limit: 10)

        #expect(history.notes.count == 10)
        #expect(history.omitted == 2)
    }
}
