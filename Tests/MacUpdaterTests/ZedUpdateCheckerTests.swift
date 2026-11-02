import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Zed official releases retain the installed channel")
struct ZedUpdateCheckerTests {
    @Test(arguments: ["dev.zed.Zed", "dev.zed.Zed-Preview"], ["aarch64", "x86_64"])
    func requestUsesTheInstalledChannelAndMacArchitecture(bundleID: String, architecture: String) throws {
        let checker = ZedUpdateChecker(client: FakeHTTP.client(ok: "{}"), architecture: architecture)
        let plan = try #require(checker.plan(for: app(bundleID: bundleID)), "Official Zed bundles need their own release check")
        let channel = bundleID == "dev.zed.Zed" ? "stable" : "preview"
        #expect(plan.request.url.host == "cloud.zed.dev")
        #expect(plan.request.url.path == "/releases/\(channel)/latest/asset")
        let query = URLComponents(url: plan.request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Set(query.map { "\($0.name)=\($0.value ?? "")" }) == ["os=macos", "arch=\(architecture)", "asset=zed"])
        #expect(plan.request.method == "GET")
        #expect(plan.request.body == nil)
    }

    @Test(arguments: ["dev.zed.Zed", "dev.zed.Zed-Preview"])
    func aNewerReleaseUsesTheAppsOwnUpdater(bundleID: String) async throws {
        let checker = ZedUpdateChecker(client: FakeHTTP.client(ok: release("2.0.0")), architecture: "aarch64")
        let result = await checker.check(app: app(bundleID: bundleID))
        guard case .outdated(let row) = result else {
            Issue.record("The official release must expose a newer Zed version")
            return
        }
        let channel = bundleID == "dev.zed.Zed" ? "stable" : "preview"
        #expect(row.installedVersion == "1.0.0")
        #expect(row.availableVersion == "2.0.0")
        #expect(row.source.badgeLabel == "Zed")
        #expect(row.source.updateActionKind == .launchAppWithReleases(URL(string: "https://zed.dev/releases/\(channel)")))
        #expect(row.source.supportsVendorCompletion)
        #expect(row.completionRequirement == .init(version: "2.0.0", field: .shortVersion, scheme: .semver))
    }

    @Test(arguments: ["1.0.0", "0.9.0"])
    func currentAndOlderReleasesDoNotOfferDowngrades(version: String) async {
        let checker = ZedUpdateChecker(client: FakeHTTP.client(ok: release(version)), architecture: "aarch64")
        #expect(await checker.check(app: app()) == .upToDate)
    }

    @Test(arguments: ["", "{}", #"{"version":""}"#, #"{"version":"unknown"}"#, #"{"version":"2.invalid.0"}"#])
    func malformedReleasesStayUnconfirmed(body: String) async {
        let checker = ZedUpdateChecker(client: FakeHTTP.client(ok: body), architecture: "aarch64")
        #expect(await checker.check(app: app()) == .failed)
    }

    @Test func sourceOutagesDoNotClaimThatZedIsCurrent() async {
        let checker = ZedUpdateChecker(client: FakeHTTP.client(status: 503), architecture: "aarch64")
        #expect(await checker.check(app: app()) == .unavailable)
    }

    @Test(arguments: ["dev.zed.Zed-Nightly", "dev.zed.Zed-Dev", "dev.zed.Zed-Custom", "com.example.Zed"])
    func unsupportedChannelsAndNameOnlyMatchesHaveNoStableFallback(bundleID: String) {
        let checker = ZedUpdateChecker(client: FakeHTTP.client(ok: release("2.0.0")), architecture: "aarch64")
        #expect(checker.plan(for: app(bundleID: bundleID)) == nil)
    }

    @Test(arguments: ["", "unknown", "1.invalid.0"])
    func anUncomparableInstalledVersionHasNoReleasePlan(version: String) {
        let checker = ZedUpdateChecker(client: FakeHTTP.client(ok: release("2.0.0")), architecture: "aarch64")
        #expect(checker.plan(for: app(version: version)) == nil)
    }

    @Test func catalogReportingRecognizesOnlySupportedChannels() {
        #expect(CatalogReporting.hasKnownUpdateSource(app(), catalog: AppCatalog()))
        #expect(CatalogReporting.hasKnownUpdateSource(app(bundleID: "dev.zed.Zed-Preview"), catalog: AppCatalog()))
        #expect(!CatalogReporting.hasKnownUpdateSource(app(bundleID: "dev.zed.Zed-Nightly"), catalog: AppCatalog()))
    }

    @Test(arguments: ["dev.zed.Zed-Preview", "dev.zed.Zed-Nightly"])
    func stableCaskCannotOfferAVersionForAnotherChannel(bundleID: String) {
        var installed = app(bundleID: bundleID)
        installed.caskToken = "zed"
        #expect(ManualUpdateScanner.caskVersionCheck(app: installed, brewTrackedVersion: nil,
                                                   latestCaskVersions: ["zed": "9.0.0"]) == nil)
        #expect(ManualUpdateScanner.caskMetadataDriftRows(installedApps: [installed],
                                                         brewCaskVersions: ["zed": "9.0.0"], alreadyListedTokens: []).isEmpty)
    }

    @Test(arguments: ["dev.zed.Zed-Preview", "dev.zed.Zed-Nightly"])
    func aRollbackMarkerCannotOfferTheWrongChannel(bundleID: String) {
        var installed = app(bundleID: bundleID)
        installed.caskToken = "zed"
        installed.isManagedByBrew = true
        #expect(ManualUpdateScanner.rolledBackRows(rolledBackTokens: ["zed"], installedApps: [installed],
                                                 brewCaskVersions: ["zed": "9.0.0"], alreadyListedTokens: []).isEmpty)
    }

    private func app(bundleID: String = "dev.zed.Zed", version: String = "1.0.0") -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/fixture/Zed.app"), name: "Zed", bundleIdentifier: bundleID,
                        version: version, installDate: nil, updateDate: nil, isManagedByBrew: false)
    }

    private func release(_ version: String) -> String {
        "{\"version\":\"\(version)\",\"url\":\"https://example.invalid/Zed.dmg\"}"
    }
}
