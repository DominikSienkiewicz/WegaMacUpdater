import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

@Suite("Thunderbird channels remain authoritative across scan and migration")
struct ThunderbirdScanBoundaryTests {
    @Test(arguments: ["thunderbird-esr", "thunderbird-beta", "thunderbird-unknown", ""])
    func inventoryCannotOfferReleaseAdoptionToAnotherOrUnknownChannel(remotingName: String) throws {
        let fixture = try ThunderbirdBoundaryFixture(remotingName: remotingName)
        defer { fixture.remove() }
        let matcher = CaskMatcher(customMappings: [:], bundleIdentifierMappings: ["org.mozilla.thunderbird": "thunderbird"])
        let apps = try ApplicationScanner(matcher: matcher).scanApplications(
            in: fixture.root, availableCasks: [BrewCask(token: "thunderbird", name: ["Thunderbird"])])
        let app = try #require(apps.first { $0.installation == fixture.app.installation })
        #expect(app.caskToken == nil)
        #expect(app.caskMatchProvenance == nil)
        #expect(!app.isManagedByBrew)
        #expect(MigrationPlanner.matchable(candidates: [app], migrated: []).isEmpty)
    }

    @Test func matchingReleaseChannelStillSupportsMigration() throws {
        let fixture = try ThunderbirdBoundaryFixture(remotingName: "thunderbird")
        defer { fixture.remove() }
        let matcher = CaskMatcher(customMappings: [:], bundleIdentifierMappings: ["org.mozilla.thunderbird": "thunderbird"])
        let apps = try ApplicationScanner(matcher: matcher).scanApplications(
            in: fixture.root, availableCasks: [BrewCask(token: "thunderbird", name: ["Thunderbird"])])
        #expect(MigrationPlanner.matchable(candidates: apps, migrated: []).count == 1)
    }

    @Test func staleMigrationCandidateCannotBypassChannelAdmission() throws {
        let fixture = try ThunderbirdBoundaryFixture(remotingName: "thunderbird-esr")
        defer { fixture.remove() }
        #expect(MigrationPlanner.matchable(candidates: [fixture.app], migrated: []).isEmpty)
    }

    @Test func foreignCaskOwnershipDoesNotSuppressTheInstallation() throws {
        let fixture = try ThunderbirdBoundaryFixture(remotingName: "thunderbird-esr")
        defer { fixture.remove() }
        var managed = fixture.app
        managed.isManagedByBrew = true
        let routed = ManualUpdateScanner.routeDistinctInstallations(
            [managed], caskAppPaths: ["thunderbird": fixture.app.path], brewOutdatedCasks: ["thunderbird"])
        #expect(routed.count == 1)
        let app = try #require(routed.first)
        #expect(app.installation == fixture.app.installation)
        #expect(app.caskToken == nil)
        #expect(app.caskMatchProvenance == nil)
        #expect(!app.isManagedByBrew)
    }

    @Test func reportCannotAttachReleasePoliciesToESROffers() throws {
        let fixture = try ThunderbirdBoundaryFixture(remotingName: "thunderbird-esr")
        defer { fixture.remove() }
        let row = ManualOutdatedApp(name: "Thunderbird", path: fixture.app.path,
                                    installedVersion: "140.4.0", availableVersion: "140.5.0esr",
                                    source: .thunderbird(channel: .esr), bundleIdentifier: fixture.app.bundleIdentifier)
        let report = ManualUpdateScanner.makeReport(
            collected: [row], observations: [], installations: [fixture.app],
            brewOwnership: .init(paths: ["thunderbird": fixture.app.path], tracked: ["thunderbird"], available: true,
                                 unconfirmedCandidates: [:]), uncheckedSources: [])
        #expect(report.apps.first?.caskPolicyToken == nil)
        #expect(report.installations.first?.caskToken == nil)
        #expect(!report.installations.contains { $0.sources.contains { $0.source == "Homebrew" } })
    }

    @Test func reportDoesNotRestoreAForeignUnconfirmedCaskCandidate() throws {
        let fixture = try ThunderbirdBoundaryFixture(remotingName: "thunderbird-esr")
        defer { fixture.remove() }
        let report = ManualUpdateScanner.makeReport(
            collected: [], observations: [], installations: [fixture.app],
            brewOwnership: .init(paths: [:], tracked: ["thunderbird"], available: true,
                                 unconfirmedCandidates: [fixture.app.installation: "thunderbird"]), uncheckedSources: [])
        #expect(report.installations.first?.unconfirmedCaskToken == nil)
    }

    @Test(arguments: ["thunderbird-unknown", "thunderbird-beta"])
    func fullScanRetainsUnavailableEvidenceForUnknownChannelOrUnnumberedBeta(remotingName: String) async throws {
        let fixture = try ThunderbirdBoundaryFixture(remotingName: remotingName, version: "146.0")
        defer { fixture.remove() }
        let (defaults, teardown) = TestDefaults.isolated("thunderbird-unavailable-scan")
        defer { teardown() }
        let cache = fixture.root.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cache).save([BrewCask(token: "thunderbird", name: ["Thunderbird"])])
        let scanner = ManualUpdateScanner(
            brewService: BrewService(locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                                     runner: ThunderbirdBoundaryBrewRunner()),
            scanDirectories: [fixture.root], caskCacheURL: cache, maxConcurrentChecks: 1,
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(ok: #"{"tag_name":"0.0.0","draft":false,"prerelease":false}"#)),
                rollbackLedger: CaskRollbackLedger(defaults: defaults), javaRuntimeDirectories: [],
                adobeUninstallDirectory: fixture.root.appendingPathComponent("no-adobe"),
                sparkleChecker: SparkleUpdateChecker(client: FakeHTTP.client(status: 503), feedOverrides: [:]),
                vendorClient: FakeHTTP.client(ok: #"{"LATEST_THUNDERBIRD_VERSION":"147.0","LATEST_THUNDERBIRD_DEVEL_VERSION":"147.0b1"}"#)
            ))
        let report = await scanner.scanReport()
        let check = try #require(report.installations.first { InstallationIdentity(path: $0.path) == fixture.app.installation })
        #expect(check.sources.contains { $0.source.hasPrefix("Thunderbird") && $0.outcome == .failed })
        #expect(check.lastSuccessfulCheck == nil)
        #expect(report.uncheckedSources.contains { $0.hasPrefix("Thunderbird") })
        #expect(!report.apps.contains { InstallationIdentity(path: $0.path) == fixture.app.installation })
    }
}

private struct ThunderbirdBoundaryFixture {
    let root: URL
    let app: ApplicationInfo

    init(remotingName: String, version: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = root.appendingPathComponent("Thunderbird.app")
        let resources = path.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let installed = version ?? (remotingName == "thunderbird-beta" ? "146.0b9" : "140.4.0")
        let plist = ["CFBundleName": "Thunderbird", "CFBundleIdentifier": "org.mozilla.thunderbird",
                     "CFBundleShortVersionString": installed, "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Contents/Info.plist"))
        if !remotingName.isEmpty {
            try "[App]\nName=Thunderbird\nRemotingName=\(remotingName)\nVersion=\(installed)\n"
                .write(to: resources.appendingPathComponent("application.ini"), atomically: true, encoding: .utf8)
        }
        app = ApplicationInfo(path: path, name: "Thunderbird", bundleIdentifier: "org.mozilla.thunderbird",
                              version: installed, installDate: nil, updateDate: nil, isManagedByBrew: false,
                              caskToken: "thunderbird", caskMatchProvenance: .bundleIdentifier)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct ThunderbirdBoundaryBrewRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: request.arguments.first == "list" ? "" : #"{"casks":[]}"#, stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
