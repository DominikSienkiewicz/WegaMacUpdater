import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Manual status survives scanner aggregation")
struct ManualScanStatusIntegrationTests {
    @Test func missingOrIncomparableInstalledCaskVersionsDoNotConfirmCurrent() async throws {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                  bundleIdentifier: nil, version: nil, installDate: nil, updateDate: nil,
                                  isManagedByBrew: false, caskToken: "example")
        let missing = try #require(ManualUpdateScanner.caskVersionCheck(app: app, brewTrackedVersion: nil,
                                                                      latestCaskVersions: ["example": "2.0"]))
        #expect(await missing().result == .notApplicable)
        let incomparable = try #require(ManualUpdateScanner.caskVersionCheck(app: app, brewTrackedVersion: "unknown",
                                                                           latestCaskVersions: ["example": "2.0"]))
        #expect(await incomparable().result == .failed)
    }

    @Test func anAbsentBrewDoesNotTurnACatalogMatchIntoAnOutage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleName": "Example", "CFBundleIdentifier": "com.example.optional", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Contents/Info.plist"))
        let cache = root.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cache).save([BrewCask(token: "example", name: ["Example"])])
        let report = await ManualUpdateScanner(
            brewService: BrewService(locator: BinaryLocator(brewCandidates: []), runner: StatusBrewRunner()),
            scanDirectories: [root], caskCacheURL: cache,
            selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(status: 503)),
            javaRuntimeDirectories: [], adobeUninstallDirectory: root.appendingPathComponent("no-adobe"),
            sparkleChecker: SparkleUpdateChecker(feedOverrides: [:])
        ).scanReport()
        #expect(report.uncheckedSources == ["GitHub · Wega"])
        #expect(report.installations.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) }?
            .sources == [.init(source: "Homebrew", outcome: .notChecked)])
    }

    @Test func menuBarCarriesTheSameEvidenceAsTheForegroundReport() async {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                  bundleIdentifier: nil, version: "1", installDate: nil, updateDate: nil,
                                  isManagedByBrew: false, caskToken: nil)
        let check = InstallationCheck(app: app, sources: [.init(source: "Sparkle", outcome: .failed)], checkedAt: Date())
        let report = ManualScanReport(apps: [], failedChecks: 1, uncheckedSources: ["Sparkle · Example"], installations: [check])
        let result = await MenuBarUpdateChecker(
            brewService: StatusBrew(), masService: StatusMas(), npmService: StatusNpm(),
            scanner: StatusScanner(report: report), operations: OperationCoordinator()
        ).availableUpdateCount()
        #expect(result.failedChecks == 1)
        #expect(result.total == 0)
        #expect(result.installationChecks == report.installations)
        #expect(result.sources.manual == report.sourceReport)
    }

    @Test func theRecordedApplicabilityAndResponseComeFromOnePlan() async {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                  bundleIdentifier: nil, version: nil, installDate: nil, updateDate: nil,
                                  isManagedByBrew: false, caskToken: nil)
        let checker = StatusPlanChecker()
        let observation = await ManualUpdateScanner.observed("Test", app, checker: checker)()
        #expect(checker.planCount == 1)
        #expect(observation.wasApplicable)
        #expect(observation.result == .notApplicable)
    }

    @Test func temporaryOutagesReachBothTheLegacyCountAndTheDetailedReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.example.status", "CFBundleShortVersionString": "1.0",
                     "CFBundleVersion": "100", "SUFeedURL": "https://example.invalid/feed.xml"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let cache = root.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cache).save([])
        func scanner() -> ManualUpdateScanner {
            ManualUpdateScanner(
                brewService: BrewService(locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                                         runner: StatusBrewRunner()),
                scanDirectories: [root, root], caskCacheURL: cache,
                selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(status: 503)),
                javaRuntimeDirectories: [], adobeUninstallDirectory: root.appendingPathComponent("no-adobe"),
                sparkleChecker: SparkleUpdateChecker(client: FakeHTTP.client(status: 503), feedOverrides: [:])
            )
        }
        let legacy = await scanner().scan()
        #expect(legacy.failedChecks == 2)
        let report = await scanner().scanReport()
        #expect(report.failedChecks == legacy.failedChecks)
        #expect(report.uncheckedSources.contains("Sparkle · Example"))
        let checks = report.installations.filter { InstallationIdentity(path: $0.path) == InstallationIdentity(path: app) }
        #expect(checks.count == 1)
        #expect(checks.first?.sources == [.init(source: "Sparkle", outcome: .failed)])
        #expect(report.apps.isEmpty)
    }
}

private final class StatusPlanChecker: VendorUpdateChecker, @unchecked Sendable {
    let client = FakeHTTP.client(ok: "{}")
    private let lock = NSLock()
    private var count = 0
    var planCount: Int { lock.withLock { count } }
    func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        lock.withLock { count += 1 }
        return VendorCheckPlan(request: HTTPRequest(url: URL(string: "https://example.invalid/check")!)) { _ in
            .decided(.notApplicable)
        }
    }
}

private struct StatusBrewRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: request.arguments.first == "list" ? "" : "{\"casks\":[]}", stderr: "")
    }
    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct StatusScanner: ManualScanning {
    let report: ManualScanReport
    func scan(brewOutdatedCasks: Set<String>) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        Issue.record("The rich-report seam must be used when available")
        return ([], 0)
    }
    func scanReport(brewOutdatedCasks: Set<String>) async -> ManualScanReport { report }
}

private struct StatusBrew: BrewOutdatedProviding {
    func outdatedGreedy() async throws -> BrewOutdated { BrewOutdated(formulae: [], casks: []) }
}
private struct StatusMas: MasOutdatedProviding {
    func outdated() async throws -> [MasOutdatedApp] { [] }
}
private struct StatusNpm: NpmOutdatedProviding {
    func outdated() async throws -> [NpmGlobalOutdated] { [] }
}
