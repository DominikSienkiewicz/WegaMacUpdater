import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

@Suite("Vendor version checks are independent of Homebrew ownership")
struct IndependentVendorCheckTests {
    @Test(arguments: VendorFixture.allCases, [false, true])
    func aManagedAppStillChecksItsOfficialFeed(vendor: VendorFixture, brewAlreadyOutdated: Bool) async throws {
        let fixture = try ScanFixture(vendor: vendor)
        defer { fixture.remove() }
        let report = await fixture.scanner().scanReport(brewOutdatedCasks: brewAlreadyOutdated ? [vendor.token] : [])
        let rows = report.apps.filter { InstallationIdentity(path: $0.path) == InstallationIdentity(path: fixture.appPath) }
        let row = try #require(rows.first, "A tracked Homebrew version must not suppress its official vendor feed")
        #expect(rows.count == 1)
        #expect(row.availableVersion == vendor.latest)
        #expect(row.source == vendor.source)
        #expect(row.source.updateActionKind == vendor.source.updateActionKind)
        #expect(row.origin == .brew)
        #expect(row.caskPolicyToken == vendor.token)
        #expect(row.bundleIdentifier == vendor.bundleID)
        #expect(UpdatePlanner.applyPolicies(rows, policies: ["c:" + vendor.token: .ignored]).isEmpty)
        let evidence = try #require(report.installations.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: fixture.appPath) })
        #expect(evidence.caskToken == vendor.token)
        #expect(evidence.sources.contains { $0.source == vendor.label && $0.outcome == .outdated })
    }

    @Test(arguments: VendorFixture.allCases)
    func vendorOutagesRemainVisibleForManagedApps(vendor: VendorFixture) async throws {
        let fixture = try ScanFixture(vendor: vendor)
        defer { fixture.remove() }
        let report = await fixture.scanner(client: FakeHTTP.client(status: 503)).scanReport()
        let evidence = try #require(report.installations.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: fixture.appPath) })
        #expect(evidence.sources.contains { $0.source == vendor.label && $0.outcome == .failed })
        #expect(report.uncheckedSources.contains(vendor.label + " · " + vendor.name))
        #expect(report.apps.isEmpty)
    }

    @Test(arguments: VendorFixture.allCases)
    func laggingBrewMetadataNeverReplacesTheNewerVendorVersion(vendor: VendorFixture) async throws {
        let fixture = try ScanFixture(vendor: vendor)
        defer { fixture.remove() }
        let report = await fixture.scanner(trackedVersion: "2.0.0").scanReport()
        let row = try #require(report.apps.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: fixture.appPath) })
        #expect(row.availableVersion == vendor.latest)
        #expect(row.source == vendor.source)
        #expect(report.apps.count == 1)
    }

    enum VendorFixture: CaseIterable, Sendable {
        case chrome, discord, googleDrive

        var name: String {
            switch self {
            case .chrome: "Google Chrome"
            case .discord: "Discord"
            case .googleDrive: "Google Drive"
            }
        }
        var label: String { self == .chrome ? "Chrome" : name }
        var token: String {
            switch self {
            case .chrome: "google-chrome"
            case .discord: "discord"
            case .googleDrive: "google-drive"
            }
        }
        var bundleID: String {
            switch self {
            case .chrome: "com.google.Chrome"
            case .discord: "com.hnc.Discord"
            case .googleDrive: "com.google.drivefs"
            }
        }
        var latest: String { "3.0.0" }
        var source: ManualOutdatedApp.UpdateSource {
            switch self {
            case .chrome: .chrome
            case .discord: .discord
            case .googleDrive: .googleDrive
            }
        }
        var body: String {
            switch self {
            case .chrome: #"{"versions":[{"version":"3.0.0"}]}"#
            case .discord: #"{"name":"3.0.0"}"#
            case .googleDrive: #"<response><app><updatecheck><manifest version="3.0.0"/></updatecheck></app></response>"#
            }
        }
    }

    private struct ScanFixture {
        let root: URL
        let appPath: URL
        let cache: URL
        let vendor: VendorFixture
        let defaults: UserDefaults
        let teardownDefaults: () -> Void

        init(vendor: VendorFixture) throws {
            self.vendor = vendor
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            appPath = root.appendingPathComponent(vendor.name + ".app")
            cache = root.appendingPathComponent("casks.json")
            (defaults, teardownDefaults) = TestDefaults.isolated("IndependentVendorCheckTests")
            try FileManager.default.createDirectory(at: appPath.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist = ["CFBundleName": vendor.name, "CFBundleIdentifier": vendor.bundleID,
                         "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1.0.0"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: appPath.appendingPathComponent("Contents/Info.plist"))
            try CaskDatabaseCache(fileURL: cache).save([
                BrewCask(token: vendor.token, name: [vendor.name], uninstallAppPaths: [appPath.path])
            ])
        }

        func scanner(client: HTTPClient? = nil, trackedVersion: String = "1.0.0") -> ManualUpdateScanner {
            ManualUpdateScanner(
                brewService: BrewService(locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                                         runner: VendorBrewRunner(token: vendor.token, version: trackedVersion)),
                scanDirectories: [root, root], caskCacheURL: cache, maxConcurrentChecks: 1,
                dependencies: .init(
                    selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(ok: #"{"tag_name":"0.0.0","draft":false,"prerelease":false}"#)),
                    rollbackLedger: CaskRollbackLedger(defaults: defaults), javaRuntimeDirectories: [],
                    adobeUninstallDirectory: root.appendingPathComponent("no-adobe"),
                    sparkleChecker: SparkleUpdateChecker(client: FakeHTTP.client(status: 503), feedOverrides: [:]),
                    vendorClient: client ?? FakeHTTP.client(ok: vendor.body)
                )
            )
        }

        func remove() {
            teardownDefaults()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private struct VendorBrewRunner: ProcessRunning {
    let token: String
    let version: String

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let output: String
        if request.arguments == ["list", "--cask", "-1"] {
            output = token
        } else if request.arguments.first == "info" {
            output = "{\"casks\":[{\"token\":\"\(token)\",\"installed\":\"\(version)\",\"version\":\"2.0.0\",\"artifacts\":[]}]}"
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
