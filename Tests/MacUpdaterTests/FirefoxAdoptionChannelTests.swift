import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

@Suite("Firefox channel ownership is preserved before Homebrew adoption")
struct FirefoxAdoptionChannelTests {
    @Test(arguments: ["esr", "beta", ""])
    func inventoryCannotOfferStableAdoptionForAnotherChannel(channel: String) throws {
        let fixture = try Fixture(channel: channel)
        defer { fixture.remove() }
        let apps = try ApplicationScanner().scanApplications(
            in: fixture.root, installedCasks: [], availableCasks: [fixture.stableCask]
        )
        let app = try #require(apps.first { $0.installation == fixture.app.installation })
        #expect(app.caskToken == nil, "A stable name match must not become an adoption candidate for this channel")
        #expect(app.caskMatchProvenance == nil)
        #expect(!app.isManagedByBrew)
        #expect(MigrationPlanner.matchable(candidates: MigrationPlanner.migrationPool(apps), migrated: []).isEmpty)
    }

    @Test(arguments: ["esr", "beta", ""])
    func routingDoesNotDropAnotherChannelWhenStableCaskIsOutdated(channel: String) throws {
        let fixture = try Fixture(channel: channel)
        defer { fixture.remove() }
        var attributed = fixture.app
        attributed.caskToken = "firefox"
        attributed.caskMatchProvenance = .installedToken
        attributed.isManagedByBrew = true
        let routed = ManualUpdateScanner.routeDistinctInstallations(
            [attributed], caskAppPaths: ["firefox": attributed.path], brewOutdatedCasks: ["firefox"]
        )
        let app = try #require(routed.first, "The unrelated cask's outdated status must not remove Firefox's own channel check")
        #expect(app.caskToken == nil)
        #expect(app.caskMatchProvenance == nil)
        #expect(!app.isManagedByBrew)
    }

    @Test(arguments: ["esr", "beta", ""])
    func packageOwnershipDoesNotReattachStablePolicyToAnotherChannel(channel: String) async throws {
        let fixture = try Fixture(channel: channel)
        defer { fixture.remove() }
        let (defaults, teardown) = TestDefaults.isolated("FirefoxAdoptionChannelTests")
        defer { teardown() }
        let cache = fixture.root.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cache).save([fixture.stableCask])
        let scanner = ManualUpdateScanner(
            brewService: BrewService(locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                                     runner: InstalledStableFirefoxRunner()),
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
        let record = try #require(report.installations.first { InstallationIdentity(path: $0.path) == fixture.app.installation })
        #expect(record.caskToken == nil, "Exact package-path attribution must still respect the installed Firefox channel")
        #expect(record.unconfirmedCaskToken == nil)
        #expect(!record.sources.contains { $0.source == "Homebrew" })
        if !channel.isEmpty {
            let row = try #require(report.apps.first { InstallationIdentity(path: $0.path) == fixture.app.installation })
            #expect(row.origin == .manual)
            #expect(row.caskPolicyToken == nil)
            #expect(UpdatePlanner.applyPolicies([row], policies: ["c:firefox": .ignored]).count == 1,
                    "Ignoring the stable cask must not hide an ESR or beta update")
        }
    }

    private static let releases = """
    {"LATEST_FIREFOX_VERSION":"141.0","LATEST_FIREFOX_RELEASED_DEVEL_VERSION":"142.0b10",
     "FIREFOX_ESR":"128.14.0esr","FIREFOX_ESR_NEXT":"140.1.0esr"}
    """

    private struct Fixture {
        let root: URL
        let app: ApplicationInfo
        var stableCask: BrewCask { BrewCask(token: "firefox", name: ["Firefox"], uninstallAppPaths: [app.path.path]) }

        init(channel: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let path = root.appendingPathComponent("Firefox.app", isDirectory: true)
            let version = channel == "beta" ? "142.0b9" : "128.13.0"
            app = ApplicationInfo(path: path, name: "Firefox", bundleIdentifier: "org.mozilla.firefox", version: version,
                                  installDate: nil, updateDate: nil, isManagedByBrew: false)
            let resources = path.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let plist = ["CFBundleName": "Firefox", "CFBundleIdentifier": "org.mozilla.firefox",
                         "CFBundleShortVersionString": version]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: path.appendingPathComponent("Contents/Info.plist"))
            if !channel.isEmpty {
                try "[App]\nName=Firefox\nRemotingName=firefox-\(channel)\nVersion=\(version)\n"
                    .write(to: resources.appendingPathComponent("application.ini"), atomically: true, encoding: .utf8)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private struct InstalledStableFirefoxRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let output = request.arguments.first == "list" ? "firefox" :
            #"{"casks":[{"token":"firefox","installed":"999.0","version":"999.0","artifacts":[]}]}"#
        return ProcessResult(exitCode: 0, stdout: output, stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
