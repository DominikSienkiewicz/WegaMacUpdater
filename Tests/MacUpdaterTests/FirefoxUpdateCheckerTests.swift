import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

@Suite("Firefox official updates preserve the installed channel")
struct FirefoxUpdateCheckerTests {
    @Test
    func manuallyInstalledStableFirefoxHasAnOfficialUpdateAndVendorHandoff() async throws {
        let fixture = try FirefoxFixture(channel: "release", version: "140.0")
        defer { fixture.remove() }
        let result = await FirefoxUpdateChecker(client: FakeHTTP.client(ok: Self.releases)).check(app: fixture.app)
        guard case .outdated(let row) = result else {
            Issue.record("Firefox stable must report the official 141.0 update; received \(result)")
            return
        }
        #expect(row.availableVersion == "141.0")
        #expect(row.installedVersion == "140.0")
        #expect(row.source.badgeLabel == "Firefox")
        #expect(row.source.updateActionKind == .launchApp)
        #expect(row.source.supportsVendorCompletion)
        #expect(row.completionRequirement?.isReached(in: fixture.app) == false)
        var updated = fixture.app
        updated.version = "141.0"
        #expect(row.completionRequirement?.isReached(in: updated) == true)
    }

    @Test(arguments: ["128.14.0", "128.14.0esr"])
    func currentESRIsNeverComparedWithNewerStable(installed: String) async throws {
        let fixture = try FirefoxFixture(channel: "esr", version: installed)
        defer { fixture.remove() }
        let result = await FirefoxUpdateChecker(client: FakeHTTP.client(ok: Self.releases)).check(app: fixture.app)
        #expect(result == .upToDate, "ESR 128.14 remains current even when stable is 141")
    }

    @Test
    func parallelESRTracksUseTheirOwnMajorVersion() async throws {
        let fixture = try FirefoxFixture(channel: "esr", version: "140.0")
        defer { fixture.remove() }
        let result = await FirefoxUpdateChecker(client: FakeHTTP.client(ok: Self.releases)).check(app: fixture.app)
        guard case .outdated(let row) = result else {
            Issue.record("The newer supported ESR track must use FIREFOX_ESR_NEXT")
            return
        }
        #expect(row.availableVersion == "140.1.0esr")
    }

    @Test
    func betaSequenceNumbersCompareNumericallyAndCompletionUsesTheSameRules() async throws {
        let fixture = try FirefoxFixture(channel: "beta", version: "142.0b9")
        defer { fixture.remove() }
        let result = await FirefoxUpdateChecker(client: FakeHTTP.client(ok: Self.releases)).check(app: fixture.app)
        guard case .outdated(let row) = result else {
            Issue.record("Published beta 142.0b10 must update beta 142.0b9")
            return
        }
        #expect(row.availableVersion == "142.0b10")
        #expect(row.completionRequirement?.isReached(in: fixture.app) == false)
        var updated = fixture.app
        updated.version = "142.0b10"
        #expect(row.completionRequirement?.isReached(in: updated) == true)
    }

    @Test
    func missingChannelIsNotAssumedToBeStable() async throws {
        let fixture = try FirefoxFixture(channel: nil, version: "128.14.0")
        defer { fixture.remove() }
        let result = await FirefoxUpdateChecker(client: FakeHTTP.client(ok: Self.releases)).check(app: fixture.app)
        #expect(result == .failed, "A known Firefox installation with unknown channel must stay unchecked")
    }

    @Test(arguments: ["nightly", "release\u{0}esr"])
    func unsupportedOrAmbiguousChannelIsNotReportedCurrent(channel: String) async throws {
        let fixture = try FirefoxFixture(channel: channel, version: "142.0")
        defer { fixture.remove() }
        let result = await FirefoxUpdateChecker(client: FakeHTTP.client(ok: Self.releases)).check(app: fixture.app)
        #expect(result == .failed)
    }

    @Test(arguments: ["{}", #"{"FIREFOX_ESR":"garbage","LATEST_FIREFOX_VERSION":"141.0"}"#, "not json"])
    func missingOrMalformedChannelReleaseIsNotCurrent(body: String) async throws {
        let fixture = try FirefoxFixture(channel: "esr", version: "128.14.0")
        defer { fixture.remove() }
        #expect(await FirefoxUpdateChecker(client: FakeHTTP.client(ok: body)).check(app: fixture.app) == .failed)
    }

    @Test
    func transportAndServerFailuresStayUnavailable() async throws {
        let fixture = try FirefoxFixture(channel: "release", version: "140.0")
        defer { fixture.remove() }
        #expect(await FirefoxUpdateChecker(client: FakeHTTP.client(status: 503)).check(app: fixture.app) == .unavailable)
        #expect(await FirefoxUpdateChecker(client: FakeHTTP.client(error: URLError(.notConnectedToInternet)))
            .check(app: fixture.app) == .unavailable)
    }

    @Test
    func anotherBrowserNeverUsesTheFirefoxFeed() async throws {
        let fixture = try FirefoxFixture(channel: "release", version: "140.0")
        defer { fixture.remove() }
        var app = fixture.app
        app.bundleIdentifier = "org.example.browser"
        #expect(FirefoxUpdateChecker(client: FakeHTTP.client(ok: Self.releases)).plan(for: app) == nil)
    }

    @Test
    func manualScanIncludesFirefoxAndRecordsItsOfficialSource() async throws {
        let fixture = try FirefoxFixture(channel: "release", version: "140.0")
        defer { fixture.remove() }
        let (defaults, teardown) = TestDefaults.isolated("FirefoxUpdateCheckerTests")
        defer { teardown() }
        try CaskDatabaseCache(fileURL: fixture.root.appendingPathComponent("casks.json")).save([])
        let scanner = ManualUpdateScanner(
            brewService: BrewService(locator: BinaryLocator(brewCandidates: [])),
            scanDirectories: [fixture.root, fixture.root],
            caskCacheURL: fixture.root.appendingPathComponent("casks.json"), maxConcurrentChecks: 1,
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(ok: #"{"tag_name":"0.0.0","draft":false,"prerelease":false}"#)),
                rollbackLedger: CaskRollbackLedger(defaults: defaults), javaRuntimeDirectories: [],
                adobeUninstallDirectory: fixture.root.appendingPathComponent("no-adobe"),
                sparkleChecker: SparkleUpdateChecker(client: FakeHTTP.client(status: 503), feedOverrides: [:]),
                vendorClient: FakeHTTP.client(ok: Self.releases)
            )
        )
        let report = await scanner.scanReport()
        let installation = fixture.app.installation
        let row = try #require(report.apps.first { InstallationIdentity(path: $0.path) == installation })
        #expect(row.availableVersion == "141.0")
        #expect(row.origin == .manual)
        #expect(row.source.badgeLabel == "Firefox")
        #expect(report.installations.contains { InstallationIdentity(path: $0.path) == installation && $0.sources.contains {
            $0.source == "Firefox" && $0.outcome == .outdated
        } })
        #expect(CatalogReporting.hasKnownUpdateSource(fixture.app, catalog: AppCatalog.shared))
    }

    private static let releases = """
    {"LATEST_FIREFOX_VERSION":"141.0","LATEST_FIREFOX_RELEASED_DEVEL_VERSION":"142.0b10",
     "LATEST_FIREFOX_DEVEL_VERSION":"143.0b1","FIREFOX_ESR":"128.14.0esr","FIREFOX_ESR_NEXT":"140.1.0esr"}
    """

    @Test(arguments: ["esr", "beta", ""])
    func staleStableCaskMetadataCannotChangeFirefoxChannel(channel: String) throws {
        let fixture = try FirefoxFixture(channel: channel.isEmpty ? nil : channel, version: "128.14.0")
        defer { fixture.remove() }
        var app = fixture.app
        app.caskToken = "firefox"
        app.isManagedByBrew = true
        #expect(ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [app], brewCaskVersions: ["firefox": "999.0"], alreadyListedTokens: []
        ).isEmpty, "Metadata drift must not create a stable-channel reinstall for another Firefox channel")
        #expect(ManualUpdateScanner.rolledBackRows(
            rolledBackTokens: ["firefox"], installedApps: [app], brewCaskVersions: ["firefox": "999.0"],
            alreadyListedTokens: []
        ).isEmpty, "Rollback metadata must not create a stable-channel reinstall for another Firefox channel")
    }

    @Test
    func aBetaWithNoComparableSequenceIsUnchecked() async throws {
        let fixture = try FirefoxFixture(channel: "beta", version: "142.0")
        defer { fixture.remove() }
        #expect(await FirefoxUpdateChecker(client: FakeHTTP.client(ok: Self.releases)).check(app: fixture.app) == .failed,
                "A missing beta sequence must not make beta 142.0b10 appear older than installed 142.0")
    }

    @Test
    func ESRHandoffRequiresEvidenceFromTheESRChannel() async throws {
        let fixture = try FirefoxFixture(channel: "esr", version: "128.13.0")
        defer { fixture.remove() }
        let result = await FirefoxUpdateChecker(client: FakeHTTP.client(ok: Self.releases)).check(app: fixture.app)
        guard case .outdated(let row) = result else {
            Issue.record("An ESR handoff must retain its channel")
            return
        }
        #expect(row.source.completionSourceLabel == "Firefox ESR")
    }

    @Test(arguments: ["esr", "beta", ""])
    func aStableCaskMatchCannotChangeTheInstalledChannel(channel: String) async throws {
        let version = channel == "beta" ? "142.0b10" : "128.14.0"
        let fixture = try FirefoxFixture(channel: channel.isEmpty ? nil : channel, version: version)
        defer { fixture.remove() }
        let (defaults, teardown) = TestDefaults.isolated("FirefoxCaskChannelTests")
        defer { teardown() }
        let cache = fixture.root.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cache).save([
            BrewCask(token: "firefox", name: ["Firefox"], uninstallAppPaths: [fixture.app.path.path])
        ])
        let scanner = ManualUpdateScanner(
            brewService: BrewService(locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                                     runner: FirefoxCaskRunner()),
            scanDirectories: [fixture.root, fixture.root], caskCacheURL: cache, maxConcurrentChecks: 1,
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(ok: #"{"tag_name":"0.0.0","draft":false,"prerelease":false}"#)),
                rollbackLedger: CaskRollbackLedger(defaults: defaults), javaRuntimeDirectories: [],
                adobeUninstallDirectory: fixture.root.appendingPathComponent("no-adobe"),
                sparkleChecker: SparkleUpdateChecker(client: FakeHTTP.client(status: 503), feedOverrides: [:]),
                vendorClient: FakeHTTP.client(ok: Self.releases)
            )
        )
        let report = await scanner.scanReport()
        #expect(report.apps.filter { InstallationIdentity(path: $0.path) == fixture.app.installation }.isEmpty,
                "A matching stable Homebrew cask must not offer a different channel to ESR, beta or unknown Firefox")
    }
}

private struct FirefoxCaskRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let output = request.arguments.first == "info"
            ? #"{"casks":[{"token":"firefox","installed":null,"version":"999.0","artifacts":[]}]}"# : ""
        return ProcessResult(exitCode: 0, stdout: output, stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct FirefoxFixture {
    let root: URL
    let app: ApplicationInfo

    init(channel: String?, version: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FirefoxTests-" + UUID().uuidString)
        let path = root.appendingPathComponent("Firefox.app")
        app = ApplicationInfo(path: path, name: "Firefox", bundleIdentifier: "org.mozilla.firefox", version: version,
                              installDate: nil, updateDate: nil, isManagedByBrew: false)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleName": "Firefox", "CFBundleIdentifier": "org.mozilla.firefox",
                     "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Contents/Info.plist"))
        if let channel {
            let resources = path.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let remotingName = channel == "release" ? "firefox" : "firefox-\(channel)"
            try "[App]\nName=Firefox\nRemotingName=\(remotingName)\nVersion=\(version)\n"
                .write(to: resources.appendingPathComponent("application.ini"), atomically: true, encoding: .utf8)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

}
