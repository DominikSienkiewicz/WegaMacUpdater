import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

@Suite("Package cask installation ownership")
struct PackageCaskAttributionTests {
    @Test func anAmbiguousCopyStillReservesEveryReceiptClaim() async throws {
        let root = try TemporaryDirectory()
        let ambiguous = try root.makeApp(named: "Ambiguous", bundleIdentifier: "com.app", version: "1.0")
        let single = try root.makeApp(named: "Single", bundleIdentifier: "com.app", version: "1.0")
        let receipts = PackageReceiptLocator(runner: PackageAttributionReceiptRunner(identifiersByPath: [
            ambiguous.appendingPathComponent("Contents/Info.plist").path: "com.first\npkgid: com.second",
            single.appendingPathComponent("Contents/Info.plist").path: "com.first"
        ]))
        let result = await PackageCaskAttribution.resolve(
            installations: [app(at: ambiguous), app(at: single)], casks: [
                BrewCask(token: "package", name: ["Package"], pkgutilIdentifiers: ["com.first"]),
                BrewCask(token: "other", name: ["Other"], pkgutilIdentifiers: ["com.second"])
            ], installedTokens: ["package", "other"], receiptLocator: receipts
        )
        #expect(result.paths.isEmpty)
        #expect(result.installations.allSatisfy { $0.caskToken == nil && !$0.isManagedByBrew })
    }

    @Test func allReceiptBlocksAreConsideredBeforeChoosingAnOwner() async throws {
        let root = try TemporaryDirectory()
        let path = try root.makeApp(named: "Package", bundleIdentifier: "com.app", version: "1.0")
        let receipts = PackageReceiptLocator(runner: StubProcessRunner(result: ProcessResult(
            exitCode: 0, stdout: "pkgid: com.first\n\npkgid: com.second\n", stderr: ""
        )))
        #expect(await receipts.packageIdentifiers(forBundleAt: path) == ["com.first", "com.second"])
        let result = await PackageCaskAttribution.resolve(
            installations: [app(at: path)], casks: [
                BrewCask(token: "package", name: ["Package"], pkgutilIdentifiers: ["com.first"]),
                BrewCask(token: "other", name: ["Other"], pkgutilIdentifiers: ["com.second"])
            ], installedTokens: ["package", "other"], receiptLocator: receipts
        )
        #expect(result.paths.isEmpty)
        #expect(result.installations.first?.caskToken == nil)
    }

    @Test func literalInstallerPathOwnsOnlyThatCopyAndSharedPathIsAmbiguous() async throws {
        let root = try TemporaryDirectory()
        let owned = try root.makeApp(named: "logioptionsplus", bundleIdentifier: "com.logi.optionsplus", version: "1.0")
        let copy = try root.makeApp(named: "Copy", bundleIdentifier: "com.logi.optionsplus", version: "1.0")
        let data = try JSONSerialization.data(withJSONObject: [[
            "token": "package", "name": ["Logitech Options+"],
            "artifacts": [["uninstall": [["delete": [owned.path]]]]]
        ]])
        let casks = try JSONDecoder().decode([BrewCask].self, from: data)
        let result = await PackageCaskAttribution.resolve(
            installations: [app(at: owned), app(at: copy)], casks: casks,
            installedTokens: ["package"], receiptLocator: locator([:])
        )
        #expect(result.paths == ["package": owned])
        #expect(result.installations[0].isManagedByBrew)
        #expect(result.installations[1].caskToken == nil)
        var other = try #require(casks.first)
        other.token = "other"
        let collision = await PackageCaskAttribution.resolve(
            installations: [app(at: owned)], casks: casks + [other],
            installedTokens: ["package", "other"], receiptLocator: locator([:])
        )
        #expect(collision.paths.isEmpty)
    }

    @Test func receiptAssociationDoesNotTransferToCopiesOrAppStoreInstallations() async throws {
        let root = try TemporaryDirectory()
        let ownerPath = try root.makeApp(named: "Owned", bundleIdentifier: "com.same.app", version: "1.0")
        let copyPath = try root.makeApp(named: "Copy", bundleIdentifier: "com.same.app", version: "1.0")
        let storePath = try root.makeApp(named: "Store", bundleIdentifier: "com.same.app", version: "1.0")
        let apps = [app(at: ownerPath), app(at: copyPath), app(at: storePath, mas: true)]
        let result = await PackageCaskAttribution.resolve(
            installations: apps, casks: [BrewCask(token: "package", name: ["Package"], pkgutilIdentifiers: ["com.pkg"])],
            installedTokens: ["package"], receiptLocator: locator([ownerPath: "com.pkg", storePath: "com.pkg"])
        )

        #expect(result.paths == ["package": ownerPath])
        #expect(result.installations[0].isManagedByBrew)
        #expect(result.installations[0].caskToken == "package")
        #expect(!result.installations[1].isManagedByBrew)
        #expect(result.installations[1].caskToken == nil)
        #expect(!result.installations[2].isManagedByBrew)
        #expect(result.installations[2].caskToken == nil)
    }

    @Test func uninstalledCaskRemainsACandidateAndMissingReceiptCannotEstablishOwnership() async throws {
        let root = try TemporaryDirectory()
        let path = try root.makeApp(named: "Package", bundleIdentifier: "com.app", version: "1.0")
        let casks = [BrewCask(token: "package", name: ["Package"], pkgutilIdentifiers: ["com.pkg"])]
        let candidate = await PackageCaskAttribution.resolve(
            installations: [app(at: path)], casks: casks, installedTokens: [], receiptLocator: locator([path: "com.pkg"])
        )
        #expect(candidate.paths.isEmpty)
        #expect(candidate.installations.first?.caskToken == "package")
        #expect(candidate.installations.first?.isManagedByBrew == false)

        let missing = await PackageCaskAttribution.resolve(
            installations: [app(at: path)], casks: casks, installedTokens: ["package"], receiptLocator: locator([:])
        )
        #expect(missing.paths.isEmpty)
        #expect(missing.installations.first?.caskToken == nil)
        #expect(missing.installations.first?.isManagedByBrew == false)
    }

    @Test func sharedReceiptsAndMultipleClaimedCopiesDoNotChooseAnArbitraryOwner() async throws {
        let root = try TemporaryDirectory()
        let first = try root.makeApp(named: "First", bundleIdentifier: "com.app", version: "1.0")
        let second = try root.makeApp(named: "Second", bundleIdentifier: "com.app", version: "1.0")
        let package = BrewCask(token: "package", name: ["Package"], pkgutilIdentifiers: ["com.pkg"])
        let collision = await PackageCaskAttribution.resolve(
            installations: [app(at: first)], casks: [package, BrewCask(token: "other", name: [], pkgutilIdentifiers: ["com.pkg"])],
            installedTokens: ["package", "other"], receiptLocator: locator([first: "com.pkg"])
        )
        #expect(collision.paths.isEmpty)
        #expect(collision.installations.first?.caskToken == nil)
        let copies = await PackageCaskAttribution.resolve(
            installations: [app(at: first), app(at: second)], casks: [package], installedTokens: ["package"],
            receiptLocator: locator([first: "com.pkg", second: "com.pkg"])
        )
        #expect(copies.paths.isEmpty)
        #expect(copies.installations.allSatisfy { $0.caskToken == nil && !$0.isManagedByBrew })
    }

    @Test func literalUninstallAppPathsSurviveCacheWithoutZapOrWildcardClaims() throws {
        let json = #"[{"token":"installer","name":[],"artifacts":[{"uninstall":[{"delete":["/Applications/App.app","/Applications/*.app","relative.app","/Library/Other.bundle"]}]},{"zap":[{"trash":["/Applications/Other.app"]}]}]}]"#
        let casks = try JSONDecoder().decode([BrewCask].self, from: Data(json.utf8))
        #expect(casks.first?.uninstallAppPaths == ["/Applications/App.app"])
        let root = try TemporaryDirectory()
        let cache = CaskDatabaseCache(fileURL: root.url.appendingPathComponent("casks.json"))
        try cache.save(casks)
        #expect(try cache.loadIfFresh()?.first?.uninstallAppPaths == ["/Applications/App.app"])
        #expect(try JSONDecoder().decode(BrewCask.self, from: Data(#"{"token":"legacy","name":[]}"#.utf8)).uninstallAppPaths.isEmpty)
    }

    private func app(at path: URL, mas: Bool = false) -> ApplicationInfo {
        ApplicationInfo(path: path, name: "Package", bundleIdentifier: "com.same.app", version: "1.0",
                        installDate: nil, updateDate: nil, isManagedByBrew: false,
                        caskToken: mas ? nil : "package", isManagedByMas: mas)
    }

    private func locator(_ receipts: [URL: String]) -> PackageReceiptLocator {
        PackageReceiptLocator(runner: PackageAttributionReceiptRunner(identifiersByPath: Dictionary(
            uniqueKeysWithValues: receipts.map { ($0.key.appendingPathComponent("Contents/Info.plist").path, $0.value) }
        )))
    }

    @Test func packageAndInstallerAppsKeepExactHomebrewOwnershipInReport() async throws {
        let fixture = try PackageAttributionFixture()
        let report = await fixture.scanner.scanReport(brewOutdatedCasks: Set(fixture.paths.keys))

        for (token, path) in fixture.paths {
            let check = try #require(report.installations.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) })
            #expect(check.caskToken == token)
            #expect(check.sources.contains { $0.source == "Homebrew" && $0.outcome == .notChecked })
            #expect(check.lastSuccessfulCheck == nil)
        }
        #expect(report.apps.isEmpty)
    }
}

private final class PackageAttributionFixture {
    let root: TemporaryDirectory
    let paths: [String: URL]
    let scanner: ManualUpdateScanner
    private let teardown: () -> Void

    init() throws {
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
                runner: PackageAttributionBrewRunner(tokens: tokens)
            ),
            scanDirectories: [applications], caskCacheURL: cacheURL, maxConcurrentChecks: 1,
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(repo: "fixture/wega", currentVersion: "999.0.0",
                                                         client: FakeHTTP.client(status: 404)),
                rollbackLedger: CaskRollbackLedger(defaults: defaults), javaRuntimeDirectories: [],
                packageReceiptLocator: PackageReceiptLocator(runner: PackageAttributionReceiptRunner(
                    identifiersByPath: Dictionary(uniqueKeysWithValues: paths.compactMap { token, path in
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

private struct PackageAttributionBrewRunner: ProcessRunning {
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

private struct PackageAttributionReceiptRunner: ProcessRunning {
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
