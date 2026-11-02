import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Official UTM releases outside Homebrew")
struct UTMUpdateSupportTests {
    @Test func manualInstallationUsesOfficialReleasesWithoutACatalogEntry() async throws {
        let transport = UTMReleaseTransport()
        let checker = checker(transport: transport)
        let plan = try #require(checker.plan(for: app()))
        #expect(plan.request.url.absoluteString == "https://api.github.com/repos/utmapp/UTM/releases?per_page=100")
        #expect(plan.request.enableETag)

        let result = await checker.check(app: app())
        guard case .outdated(let update) = result else {
            Issue.record("A manually installed UTM 4.6.5 must offer the official stable 4.7.5 release")
            return
        }
        #expect(update.installedVersion == "4.6.5")
        #expect(update.availableVersion == "4.7.5")
        #expect(update.source == .github(repo: "utmapp/UTM", selfUpdates: false))
        #expect(update.source.updateActionKind == .openURL(
            URL(string: "https://github.com/utmapp/UTM/releases"), style: .githubReleases
        ))
        #expect(update.releaseNotes?.history.notes.map(\.version) == ["4.7.5", "4.7.4"])
        #expect(await transport.requestCount == 1)
    }

    @Test func manualInstallationHasAKnownSourceWithoutAHomebrewAssociation() {
        #expect(CatalogReporting.hasKnownUpdateSource(app(), catalog: AppCatalog()))
        #expect(app().caskToken == nil)
        #expect(!app().isManagedByBrew)
    }

    @Test(arguments: ["4.7.5", "4.8.0"])
    func currentAndNewerInstallationsAreNotOfferedADowngrade(version: String) async {
        let result = await checker().check(app: app(version: version))
        guard case .upToDate = result else {
            Issue.record("UTM \(version) is already at or above the stable release")
            return
        }
    }

    @Test func appStoreEvidenceKeepsUTMOnItsStoreUpdatePath() async {
        let transport = UTMReleaseTransport()
        var receiptManaged = app()
        receiptManaged.isManagedByMas = true
        var identifiedByStore = app()
        identifiedByStore.masAppID = "1538878817"
        for installation in [receiptManaged, identifiedByStore] {
            let result = await checker(transport: transport).check(app: installation)
            guard case .notApplicable = result else {
                Issue.record("App Store UTM must not use the standalone GitHub release channel")
                continue
            }
        }
        #expect(await transport.requestCount == 0)
    }

    @Test(arguments: ["com.utmapp.UTM-SE", "com.utmapp.UTM-Remote", "com.example.UTM", "com.utmapp.UTM.helper"])
    func similarlyNamedApplicationsDoNotInheritUTMReleases(bundleIdentifier: String) async {
        var installation = app()
        installation.bundleIdentifier = bundleIdentifier
        let transport = UTMReleaseTransport()
        let result = await checker(transport: transport).check(app: installation)
        guard case .notApplicable = result else {
            Issue.record("Only the official macOS UTM bundle may use this release channel")
            return
        }
        #expect(await transport.requestCount == 0)
        #expect(!CatalogReporting.hasKnownUpdateSource(installation, catalog: AppCatalog()))
    }

    @Test func anInstallationWithSparkleKeepsItsNativeUpdateChannel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("UTM.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["SUFeedURL": "https://updates.example.test/utm.xml"], format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        var installation = app()
        installation.path = contents.deletingLastPathComponent()
        #expect(SparkleUpdateChecker(feedOverrides: [:]).plan(for: installation) != nil)
        #expect(checker().plan(for: installation) == nil)
    }

    @Test func malformedOfficialResponseIsACheckFailure() async {
        let result = await checker(transport: UTMReleaseTransport(body: "invalid")).check(app: app())
        guard case .failed = result else {
            Issue.record("An unreadable UTM release response must remain a visible check failure")
            return
        }
    }

    @Test func anExplicitEmptyCatalogDisablesBuiltInReleaseChecks() {
        let checker = GitHubReleasesChecker(client: HTTPClient(transport: UTMReleaseTransport()), repos: [:])
        #expect(checker.plan(for: app()) == nil)
    }

    @Test(arguments: [
        "[]",
        """
        [{"tag_name":"v4.8.0-beta.1","draft":false,"prerelease":true},
         {"tag_name":"v4.9.0","draft":true,"prerelease":false}]
        """,
    ])
    func noStableReleaseEvidenceIsACheckFailure(body: String) async {
        let result = await checker(transport: UTMReleaseTransport(body: body)).check(app: app())
        guard case .failed = result else {
            Issue.record("No stable UTM release is missing evidence, not proof the installation is current")
            return
        }
    }

    @Test(arguments: ["unknown", "v4.x.7", "v4..7", "v4.7.5-beta.1"])
    func invalidStableTagsCannotEstablishTheLatestVersion(tag: String) async {
        let body = "[\(release(tag: tag))]"
        let result = await checker(transport: UTMReleaseTransport(body: body)).check(app: app())
        guard case .failed = result else {
            Issue.record("An invalid or prerelease UTM tag cannot establish a stable macOS release")
            return
        }
    }

    @Test(arguments: ["", "unknown", "4.x.5", "4..5"])
    func uncomparableInstalledVersionsAreCheckFailures(version: String) async {
        let result = await checker().check(app: app(version: version))
        guard case .failed = result else {
            Issue.record("UTM version '\(version)' cannot be compared reliably with the official release")
            return
        }
    }

    @Test func aMissingInstalledVersionIsACheckFailure() async {
        var installation = app()
        installation.version = nil
        let result = await checker().check(app: installation)
        guard case .failed = result else {
            Issue.record("A missing UTM version must not hide the unresolved update check")
            return
        }
    }

    @Test(arguments: ["UTM.ipa", "UTM-SE.ipa", "UTM-visionOS.ipa", "Other.dmg"])
    func releasesWithoutTheMacOSArtifactAreNotApplicableEvidence(assetName: String) async {
        let body = "[\(release(tag: "v4.7.5", assetName: assetName))]"
        let result = await checker(transport: UTMReleaseTransport(body: body)).check(app: app())
        guard case .failed = result else {
            Issue.record("The \(assetName) release artifact does not establish an update for macOS UTM")
            return
        }
    }

    @Test func missingAssetMetadataDoesNotProveAMacOSReleaseExists() async {
        let body = """
            [{"tag_name":"v4.7.5","draft":false,"prerelease":false}]
            """
        let result = await checker(transport: UTMReleaseTransport(body: body)).check(app: app())
        guard case .failed = result else {
            Issue.record("A UTM release without asset metadata is not confirmed for macOS")
            return
        }
    }

    @Test func aNewerMobileOnlyReleaseDoesNotReplaceTheLatestMacOSRelease() async {
        let body = "[\(release(tag: "v4.8.0", assetName: "UTM.ipa")),\(release(tag: "v4.7.5"))]"
        let result = await checker(transport: UTMReleaseTransport(body: body)).check(app: app())
        guard case .outdated(let update) = result else {
            Issue.record("The confirmed macOS release must remain available when a newer mobile release exists")
            return
        }
        #expect(update.availableVersion == "4.7.5")
        #expect(update.releaseNotes?.history.notes.map(\.version) == ["4.7.5"])
    }

    @Test func standaloneUTMOpensTheReleasesListInsteadOfAPotentiallyMobileOnlyLatestPage() {
        let source = ManualOutdatedApp.UpdateSource.github(repo: "utmapp/UTM", selfUpdates: false)
        #expect(source.updateActionKind == .openURL(
            URL(string: "https://github.com/utmapp/UTM/releases"), style: .githubReleases
        ))
    }

    @Test func releasesIndexUsesItsOwnConfiguredPath() throws {
        let base = try AppEndpoints.loadBundled()
        let overlay = try JSONDecoder().decode(AppEndpointsOverlay.self, from: Data("""
            {"githubReleasesIndexPage":"https://github.com/{repo}/releases?expanded=true",
             "githubReleasesPage":"https://github.com/{repo}/custom/latest"}
            """.utf8))
        let endpoints = base.overlaying(overlay)
        #expect(endpoints.githubReleasesIndexPageURL(repo: "utmapp/UTM")?.absoluteString
                == "https://github.com/utmapp/UTM/releases?expanded=true")
        #expect(endpoints.githubReleasesPageURL(repo: "utmapp/UTM")?.absoluteString
                == "https://github.com/utmapp/UTM/custom/latest")
    }

    private func release(tag: String, assetName: String = "UTM.dmg") -> String {
        """
        {"tag_name":"\(tag)","draft":false,"prerelease":false,"body":"Release notes",
         "assets":[{"name":"\(assetName)",
          "browser_download_url":"https://github.com/utmapp/UTM/releases/download/\(tag)/\(assetName)"}]}
        """
    }

    private func app(version: String = "4.6.5") -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/fixture/UTM.app"), name: "UTM", bundleIdentifier: "com.utmapp.UTM",
            version: version, installDate: nil, updateDate: nil, isManagedByBrew: false
        )
    }

    private func checker(transport: UTMReleaseTransport = UTMReleaseTransport()) -> GitHubReleasesChecker {
        GitHubReleasesChecker(client: HTTPClient(transport: transport, maxRetries: 0))
    }
}

private actor UTMReleaseTransport: HTTPTransport {
    private let body: String
    private(set) var requestCount = 0

    init(body: String = """
        [
            {"tag_name":"v4.7.4","draft":false,"prerelease":false,"body":"Previous stable",
             "assets":[{"name":"UTM.dmg",
              "browser_download_url":"https://github.com/utmapp/UTM/releases/download/v4.7.4/UTM.dmg"}]},
            {"tag_name":"v4.8.0-beta.1","draft":false,"prerelease":true},
            {"tag_name":"v5.0.0","draft":true,"prerelease":false},
            {"tag_name":"v4.7.5","draft":false,"prerelease":false,"body":"Current stable",
             "assets":[{"name":"UTM.dmg",
              "browser_download_url":"https://github.com/utmapp/UTM/releases/download/v4.7.5/UTM.dmg"}]}
        ]
        """) {
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
