import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Bruno updates from its official stable releases without Homebrew")
struct BrunoUpdateSupportTests {
    @Test func manuallyInstalledBrunoUsesTheOfficialReleaseList() throws {
        let plan = try #require(GitHubReleasesChecker().plan(for: app()))
        #expect(plan.request.url == AppEndpoints.shared.githubReleasesURL(repo: "usebruno/bruno"))
        #expect(CatalogReporting.hasKnownUpdateSource(app(), catalog: AppCatalog()))
    }

    @Test func newerStableReleaseHandsInstallationToBrunoWithAReleasePageFallback() async throws {
        let row = try await outdated()
        #expect(row.installedVersion == "4.2.1")
        #expect(row.availableVersion == "4.3.0")
        #expect(row.path == app().path)
        #expect(row.source == .github(repo: "usebruno/bruno", selfUpdates: true))
        #expect(row.source.updateActionKind == .launchAppWithReleases(URL(string: "https://github.com/usebruno/bruno/releases/latest")))
        #expect(row.source.supportsVendorCompletion)
        #expect(row.completionRequirement == .init(version: "4.3.0", scheme: .semver))
    }

    @Test func publishedStableVersionsDetermineOrderingAndHistory() async throws {
        let payload = """
        [
          {"tag_name":"v4.2.2","draft":false,"prerelease":false},
          {"tag_name":"v5.0.0","draft":true,"prerelease":false},
          {"tag_name":"v6.0.0-beta.1","draft":false,"prerelease":true},
          {"tag_name":"v7.0.0-beta.1","draft":false,"prerelease":false},
          {"tag_name":"v999.invalid.0","draft":false,"prerelease":false},
          {"tag_name":"v4.3.0","draft":false,"prerelease":false,"body":"Stable release"}
        ]
        """
        let row = try await outdated(payload: payload)
        #expect(row.availableVersion == "4.3.0")
        #expect(row.releaseNotes?.history.notes.map(\.version) == ["4.3.0", "4.2.2"])
    }

    @Test(arguments: ["4.3.0", "4.4.0"])
    func equalOrNewerInstalledStableVersionIsCurrent(version: String) async {
        #expect(await checker().check(app: app(version: version)) == .upToDate)
    }

    @Test(arguments: [nil, "", "unknown", "4.invalid.0", "4.3", "4.3.0-beta.1", "04.3.0"] as [String?])
    func missingInvalidOrPrereleaseInstalledVersionsDoNotUseTheStableChannel(version: String?) {
        #expect(GitHubReleasesChecker().plan(for: app(version: version)) == nil)
    }

    @Test(arguments: ["", "release-4.3.0", "v999.invalid.0", "v4.3", "v04.3.0", "v4.3.0-beta.1"])
    func unusableStableTagsNeverClaimTheAppIsCurrent(tag: String) async {
        #expect(await checker(payload: release(tag)).check(app: app()) == .failed)
    }

    @Test func aReleaseListWithoutStableEvidenceDoesNotClaimTheAppIsCurrent() async {
        for payload in ["[]", #"[{"tag_name":"v5.0.0","draft":true,"prerelease":false}]"#,
                        #"[{"tag_name":"v5.0.0-beta.1","draft":false,"prerelease":true}]"#] {
            #expect(await checker(payload: payload).check(app: app()) == .failed)
        }
    }

    @Test func onlyTheExactBundleIdentifierIsSupportedRegardlessOfDisplayName() {
        for identifier in [nil, "com.usebruno.app.beta", "com.usebruno.app.helper", "org.other.Bruno"] as [String?] {
            let other = app(bundleIdentifier: identifier)
            #expect(GitHubReleasesChecker().plan(for: other) == nil)
            #expect(!CatalogReporting.hasKnownUpdateSource(other, catalog: AppCatalog()))
        }
        #expect(GitHubReleasesChecker().plan(for: app(name: "My API Client")) != nil)
    }

    @Test func anExplicitRepositoryMapCanDisableOrOverrideTheBuiltInSupport() async throws {
        #expect(GitHubReleasesChecker(repos: [:]).plan(for: app()) == nil)
        let entry = GitHubCatalogEntry(bundleId: "com.usebruno.app", repo: "fixture/releases", caskToken: "fixture")
        let checker = GitHubReleasesChecker(client: FakeHTTP.client(ok: release("v4.3.0")), repos: [entry.bundleId: entry])
        let plan = try #require(checker.plan(for: app()))
        #expect(plan.request.url == AppEndpoints.shared.githubReleasesURL(repo: "fixture/releases"))
        guard case .outdated(let row) = await checker.check(app: app()) else {
            Issue.record("Explicit catalog entry should retain its update source")
            return
        }
        #expect(row.source == .github(repo: "fixture/releases", selfUpdates: false))
    }

    @Test func transportAndPayloadFailuresRemainVisible() async {
        let offline = GitHubReleasesChecker(client: FakeHTTP.client(error: URLError(.notConnectedToInternet)))
        #expect(await offline.check(app: app()) == .unavailable)
        let forbidden = GitHubReleasesChecker(client: FakeHTTP.client(status: 403))
        #expect(await forbidden.check(app: app()) == .failed)
        #expect(await checker(payload: "invalid JSON").check(app: app()) == .failed)
    }

    @Test func completionRequiresTheSameInstallationToReachTheAdvertisedVersion() async throws {
        var row = try await outdated()
        row.bundleIdentifier = "com.usebruno.app"
        let current = app(version: "4.3.0")
        let complete = VendorUpdateCompletionChecker(readApplication: { _ in current }, checkSource: { _, _ in .upToDate })
        #expect(try await complete.check(row).outcome == .confirmed)
        let unchanged = app()
        let pending = VendorUpdateCompletionChecker(readApplication: { _ in unchanged }, checkSource: { _, _ in .upToDate })
        #expect(try await pending.check(row).outcome == .unconfirmed(.targetNotReached))
        let foreign = app(version: "4.3.0", bundleIdentifier: "com.other.app")
        let replaced = VendorUpdateCompletionChecker(readApplication: { _ in foreign }, checkSource: { _, _ in .upToDate })
        #expect(try await replaced.check(row).outcome == .unconfirmed(.identityChanged))
    }

    private func app(version: String? = "4.2.1", bundleIdentifier: String? = "com.usebruno.app", name: String = "Bruno") -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Bruno.app"), name: name,
                        bundleIdentifier: bundleIdentifier, version: version, installDate: nil, updateDate: nil,
                        isManagedByBrew: false)
    }

    private func release(_ tag: String) -> String {
        #"[{"tag_name":"\#(tag)","draft":false,"prerelease":false}]"#
    }

    private func checker(payload: String? = nil) -> GitHubReleasesChecker {
        GitHubReleasesChecker(client: FakeHTTP.client(ok: payload ?? release("v4.3.0")))
    }

    private func outdated(payload: String? = nil) async throws -> ManualOutdatedApp {
        let result = await checker(payload: payload).check(app: app())
        guard case .outdated(let row) = result else {
            Issue.record("A newer official stable release should produce an actionable Bruno update; received \(result)")
            throw MissingUpdate.expectedOutdated
        }
        return row
    }

    private enum MissingUpdate: Error { case expectedOutdated }
}
