import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

@Suite("Manual Zed installations use official channel evidence")
struct ZedManualScanTests {
    @Test(arguments: ["dev.zed.Zed-Preview", "dev.zed.Zed-Nightly"])
    func aStableNameMatchCannotBecomeACaskAdoptionCandidate(bundleID: String) throws {
        let fixture = try ZedScanFixture(bundleID: bundleID)
        defer { fixture.remove() }
        let apps = try ApplicationScanner().scanApplications(in: fixture.root,
            availableCasks: [BrewCask(token: "zed", name: ["Zed"])])
        let app = try #require(apps.first)
        #expect(app.caskToken == nil)
        #expect(app.caskMatchProvenance == nil)
        #expect(!app.isManagedByBrew)
    }

    @Test(arguments: ["dev.zed.Zed", "dev.zed.Zed-Preview"])
    func manualZedUsesItsOwnReleaseEvenWhenAStableCaskHasAHigherVersion(bundleID: String) async throws {
        let fixture = try ZedScanFixture(bundleID: bundleID)
        defer { fixture.remove() }
        let report = await fixture.scanner().scanReport()
        let rows = report.apps.filter { InstallationIdentity(path: $0.path) == fixture.installation }
        let row = try #require(rows.first, "A manual Zed installation must be checked independently of Homebrew")
        #expect(rows.count == 1)
        #expect(row.availableVersion == "2.0.0")
        #expect(row.source.badgeLabel == "Zed")
        #expect(row.bundleIdentifier == bundleID)
        #expect(row.origin == .manual)
        #expect(row.caskPolicyToken == nil)
        let evidence = try #require(report.installations.first { InstallationIdentity(path: $0.path) == fixture.installation })
        #expect(evidence.bundleIdentifier == bundleID)
        #expect(evidence.sources.contains { $0.source == "Zed" && $0.outcome == .outdated })
        #expect(!evidence.sources.contains { $0.source == "Cask" && $0.outcome == .outdated })
    }

    @Test func unknownChannelIsNeverDeclaredCurrentFromTheStableCask() async throws {
        let fixture = try ZedScanFixture(bundleID: "dev.zed.Zed-Nightly")
        defer { fixture.remove() }
        let report = await fixture.scanner().scanReport()
        #expect(!report.apps.contains { InstallationIdentity(path: $0.path) == fixture.installation })
        let evidence = try #require(report.installations.first { InstallationIdentity(path: $0.path) == fixture.installation })
        #expect(evidence.bundleIdentifier == "dev.zed.Zed-Nightly")
        #expect(evidence.lastSuccessfulCheck == nil)
        #expect(!evidence.sources.contains { $0.outcome == .current || $0.outcome == .outdated })
    }

    @Test func aFailedOfficialCheckRemainsVisibleWithoutACaskFallback() async throws {
        let fixture = try ZedScanFixture(bundleID: "dev.zed.Zed")
        defer { fixture.remove() }
        let report = await fixture.scanner(client: FakeHTTP.client(status: 503)).scanReport()
        #expect(!report.apps.contains { InstallationIdentity(path: $0.path) == fixture.installation })
        #expect(report.uncheckedSources.contains("Zed · Zed"))
        let evidence = try #require(report.installations.first { InstallationIdentity(path: $0.path) == fixture.installation })
        #expect(evidence.bundleIdentifier == "dev.zed.Zed")
        #expect(evidence.sources.contains { $0.source == "Zed" && $0.outcome == .failed })
        #expect(evidence.lastSuccessfulCheck == nil)
    }
}

private struct ZedScanFixture {
    let root: URL
    let appPath: URL
    let cache: URL
    let defaults: UserDefaults
    let teardownDefaults: () -> Void
    var installation: InstallationIdentity { InstallationIdentity(path: appPath) }

    init(bundleID: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        appPath = root.appendingPathComponent("Zed.app", isDirectory: true)
        cache = root.appendingPathComponent("casks.json")
        (defaults, teardownDefaults) = TestDefaults.isolated("ZedManualScanTests")
        try FileManager.default.createDirectory(at: appPath.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleName": "Zed", "CFBundleIdentifier": bundleID,
                     "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1.0.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: appPath.appendingPathComponent("Contents/Info.plist"))
        try CaskDatabaseCache(fileURL: cache).save([BrewCask(token: "zed", name: ["Zed"], uninstallAppPaths: [appPath.path])])
    }

    func scanner(client: HTTPClient? = nil) -> ManualUpdateScanner {
        ManualUpdateScanner(
            brewService: BrewService(locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]), runner: ZedScanBrewRunner()),
            scanDirectories: [root], caskCacheURL: cache, maxConcurrentChecks: 1,
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(ok: #"{"tag_name":"0.0.0","draft":false,"prerelease":false}"#)),
                rollbackLedger: CaskRollbackLedger(defaults: defaults), javaRuntimeDirectories: [],
                adobeUninstallDirectory: root.appendingPathComponent("no-adobe"),
                sparkleChecker: SparkleUpdateChecker(client: FakeHTTP.client(status: 503), feedOverrides: [:]),
                vendorClient: client ?? FakeHTTP.client(ok: #"{"version":"2.0.0","url":"https://example.invalid/Zed.dmg"}"#)
            )
        )
    }

    func remove() {
        teardownDefaults()
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ZedScanBrewRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let output: String
        if request.arguments == ["list", "--cask", "-1"] {
            output = ""
        } else if request.arguments.contains("--installed") {
            output = #"{"casks":[]}"#
        } else if request.arguments.first == "info" {
            output = #"{"casks":[{"token":"zed","installed":null,"version":"9.0.0","artifacts":[]}]}"#
        } else {
            Issue.record("Unexpected process request: \(request.arguments)")
            output = "{}"
        }
        return ProcessResult(exitCode: 0, stdout: output, stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
