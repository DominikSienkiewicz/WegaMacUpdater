import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

@Suite("Unconfirmed cask associations remain evidence only", .serialized)
struct UnconfirmedCaskAssociationTests {
    @Test func missingReceiptsRemainVisibleWithoutManagerOrActionAuthority() async throws {
        let fixture = try UnconfirmedPackageFixture()
        let report = await fixture.scanner.scanReport(brewOutdatedCasks: Set(fixture.paths.keys))
        let managers = ScanSourceReports(brew: .init(outcome: .succeeded))
        let resolved = InstallationCheck.resolvingManagers(report.installations, reports: managers, brew: .init(formulae: [], casks: []))
        for token in ["cloudflare-warp", "google-drive"] {
            let path = try #require(fixture.paths[token])
            let app = ApplicationInfo(path: path, name: token, bundleIdentifier: "fixture." + token, version: "1.0",
                                      installDate: nil, updateDate: nil, isManagedByBrew: false)
            let check = try #require(resolved.first { InstallationIdentity(path: $0.path) == app.installation })
            #expect(check.unconfirmedCaskToken == token)
            #expect(check.caskToken == nil)
            #expect(check.sources.contains { $0.source == "Homebrew" && $0.outcome == .notChecked && $0.policyKey == nil })
            #expect(check.status(for: app) == .notChecked)
            #expect(check.lastSuccessfulCheck == nil)
            #expect(!report.apps.contains { InstallationIdentity(path: $0.path) == app.installation && $0.source == .cask(token: token) })
        }
    }

    @Test func anUnverifiedPackageMatchRetainsOnlyTheCandidate() async throws {
        let app = exampleApp()
        let cask = BrewCask(token: "google-drive", name: ["Example"], pkgutilIdentifiers: ["fixture.receipt"])
        let attribution = await PackageCaskAttribution.resolve(
            installations: [app], casks: [cask], installedTokens: ["google-drive"],
            receiptLocator: PackageReceiptLocator(runner: UnconfirmedPackageReceiptRunner(identifiersByPath: [:]))
        )
        let attributed = try #require(attribution.installations.first)
        #expect(attribution.unconfirmedCandidates[app.installation] == "google-drive")
        #expect(attribution.paths.isEmpty)
        #expect(attributed.caskToken == nil)
        #expect(!attributed.isManagedByBrew)
    }

    @Test func confirmedReceiptsUseTheVerifiedSourceWithoutTheNote() async throws {
        let fixture = try UnconfirmedPackageFixture(missingReceipts: [])
        let report = await fixture.scanner.scanReport(brewOutdatedCasks: Set(fixture.paths.keys))
        for token in ["cloudflare-warp", "google-drive"] {
            let path = try #require(fixture.paths[token])
            let check = try #require(report.installations.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) })
            #expect(check.caskToken == token)
            #expect(check.unconfirmedCaskToken == nil)
        }
    }

    @Test func candidateDoesNotBecomeAnUpdatePolicyAliasAndSurvivesSnapshots() throws {
        let app = exampleApp()
        var check = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .notChecked)], checkedAt: Date())
        check.unconfirmedCaskToken = "google-drive"
        let row = ManualOutdatedApp(name: app.name, path: app.path, installedVersion: "1", availableVersion: "2",
                                    source: .sparkle, bundleIdentifier: app.bundleIdentifier)
        #expect(UpdatePlanner.attachingCaskPolicies(to: [row], installationChecks: [check]).first?.caskPolicyToken == nil)
        var verified = check
        verified.unconfirmedCaskToken = nil
        verified.caskToken = "google-drive"
        #expect(UpdatePlanner.attachingCaskPolicies(to: [row], installationChecks: [verified]).first?.caskPolicyToken == "google-drive")
        let snapshot = ScanSnapshot(scannedAt: Date(), brew: nil, mas: [], npm: [], manual: [], installationChecks: [check])
        let restored = try JSONDecoder().decode(ScanSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.installationChecks.first?.unconfirmedCaskToken == "google-drive")
        #expect(restored.installationChecks.first?.caskToken == nil)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(check)) as? [String: Any])
        legacy.removeValue(forKey: "unconfirmedCaskToken")
        let old = try JSONDecoder().decode(InstallationCheck.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.unconfirmedCaskToken == nil)
    }

    @Test func aCandidateAloneIsNotACompletedSuccessfulCheck() {
        let app = exampleApp()
        var check = InstallationCheck(app: app, sources: [], checkedAt: Date())
        check.unconfirmedCaskToken = "google-drive"
        #expect(check.status(for: app) == .notChecked)
        check.sources = [.init(source: "Sparkle", outcome: .current)]
        check.stampSuccess()
        #expect(check.lastSuccessfulCheck == nil)
        #expect(check.status(for: app) == .notChecked)
    }

    @Test func uninstalledCandidatesAndAppStoreCopiesDoNotAcquireTheNote() async {
        let app = exampleApp()
        var storeCopy = app
        storeCopy.isManagedByMas = true
        let cask = BrewCask(token: "google-drive", name: ["Example"], pkgutilIdentifiers: ["fixture.receipt"])
        let locator = PackageReceiptLocator(runner: UnconfirmedPackageReceiptRunner(identifiersByPath: [:]))
        let uninstalled = await PackageCaskAttribution.resolve(installations: [app], casks: [cask], installedTokens: [], receiptLocator: locator)
        let appStore = await PackageCaskAttribution.resolve(installations: [storeCopy], casks: [cask], installedTokens: ["google-drive"], receiptLocator: locator)
        #expect(uninstalled.unconfirmedCandidates.isEmpty)
        #expect(appStore.unconfirmedCandidates.isEmpty)
    }

    private func exampleApp() -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Fixtures/Example.app"), name: "Example", bundleIdentifier: "fixture.example",
                        version: "1", installDate: nil, updateDate: nil, isManagedByBrew: false, caskToken: "google-drive")
    }
}
private final class UnconfirmedPackageFixture {
    let root: TemporaryDirectory
    let paths: [String: URL]
    let scanner: ManualUpdateScanner
    private let teardown: () -> Void

    init(missingReceipts: Set<String> = ["cloudflare-warp", "google-drive"]) throws {
        let root = try TemporaryDirectory()
        self.root = root
        let applications = try root.makeSubdirectory("Applications")
        let names = ["cloudflare-warp": "Cloudflare WARP", "google-drive": "Google Drive",
                     "zoom": "zoom.us", "logi-options+": "logioptionsplus"]
        let tokens = names.keys.sorted()
        var paths: [String: URL] = [:]
        for (token, name) in names {
            paths[token] = try root.makeApp(named: name, bundleIdentifier: "fixture." + token,
                                            version: "1.0", in: applications)
        }
        self.paths = paths
        let catalog: [[String: Any]] = tokens.map { token in
            var uninstall: [String: Any] = [:]
            if let receipt = Self.receiptIDs[token] { uninstall["pkgutil"] = receipt }
            if token == "logi-options+", let path = paths[token] { uninstall["delete"] = [path.path] }
            return ["token": token, "name": [names[token] ?? token], "artifacts": [["uninstall": [uninstall]]]]
        }
        let cacheURL = root.url.appendingPathComponent("casks.json")
        try JSONSerialization.data(withJSONObject: catalog).write(to: cacheURL)
        let (defaults, teardown) = TestDefaults.isolated("package-attribution")
        self.teardown = teardown
        scanner = ManualUpdateScanner(
            brewService: BrewService(
                locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                runner: UnconfirmedPackageBrewRunner(tokens: tokens)
            ),
            scanDirectories: [applications], caskCacheURL: cacheURL, maxConcurrentChecks: 1,
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(repo: "fixture/wega", currentVersion: "999.0.0",
                                                         client: FakeHTTP.client(status: 404)),
                rollbackLedger: CaskRollbackLedger(defaults: defaults), javaRuntimeDirectories: [],
                packageReceiptLocator: PackageReceiptLocator(runner: UnconfirmedPackageReceiptRunner(
                    identifiersByPath: Dictionary(uniqueKeysWithValues: paths.filter { !missingReceipts.contains($0.key) }.compactMap { token, path in
                        Self.receiptIDs[token].map { (path.appendingPathComponent("Contents/Info.plist").path, $0) }
                    })
                )),
                adobeCatalogClient: AdobeCatalogClient(cache: nil, client: FakeHTTP.client(status: 404)),
                adobeUninstallDirectory: root.url.appendingPathComponent("NoAdobe")
            )
        )
    }

    deinit { teardown() }

    private static let receiptIDs = [
        "cloudflare-warp": "com.cloudflare.1dot1dot1dot1.macos",
        "google-drive": "com.google.drivefs.arm64",
        "zoom": "us.zoom.pkg.videomeeting"
    ]
}

private struct UnconfirmedPackageBrewRunner: ProcessRunning {
    let tokens: [String]

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let payload: Any
        switch request.arguments {
        case ["list", "--cask", "-1"]:
            return ProcessResult(exitCode: 0, stdout: (tokens + ["direct-app"]).joined(separator: "\n"), stderr: "")
        case ["info", "--installed", "--json=v2"]:
            payload = ["casks": tokens.map { ["token": $0, "installed": "1.0"] }]
        case let arguments where arguments.starts(with: ["info", "--cask", "--json=v2"]):
            payload = ["casks": [["token": "direct-app", "artifacts": [["app": ["Direct.app"]]]]]]
        default:
            return ProcessResult(exitCode: 2, stdout: "", stderr: "Unexpected request")
        }
        return ProcessResult(exitCode: 0,
                             stdout: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self),
                             stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct UnconfirmedPackageReceiptRunner: ProcessRunning {
    let identifiersByPath: [String: String]

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let probe = request.arguments.last.map { InstallationIdentity(path: $0) }
        let identifier = identifiersByPath.first { InstallationIdentity(path: $0.key) == probe }?.value
        return ProcessResult(exitCode: 0, stdout: identifier.map { "pkgid: \($0)\n" } ?? "", stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
