import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

@Suite("Java runtime installation attribution")
struct JavaRuntimeInstallationAttributionTests {
    @Test func outdatedTemurinRetainsItsExactInstallationWithoutDuplicatingTheUpdate() async throws {
        let fixture = try JavaAttributionFixture()
        let path = try fixture.addRuntime("temurin-27.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")

        let report = await fixture.scanner().scanReport(brewOutdatedCasks: ["temurin"])

        let installation = try #require(report.installations.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) })
        #expect(installation.caskToken == "temurin")
        #expect(installation.sources.contains { $0.source == "Homebrew" && $0.outcome == .notChecked })
        #expect(!report.apps.contains { $0.path.pathExtension == "jdk" })
    }

    @Test func currentTrackedTemurinInheritsOnlyItsHomebrewResult() async throws {
        let fixture = try JavaAttributionFixture()
        let path = try fixture.addRuntime("temurin-27.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")
        let report = await fixture.scanner().scanReport()
        let resolved = InstallationCheck.resolvingManagers(
            report.installations,
            reports: ScanSourceReports(brew: .init(outcome: .succeeded)),
            brew: BrewOutdated(formulae: [], casks: [])
        )

        let installation = try #require(resolved.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) })
        #expect(installation.caskToken == "temurin")
        #expect(installation.sources == [.init(source: "Homebrew", outcome: .current, policyKey: "c:temurin")])
        #expect(!report.apps.contains { $0.path.pathExtension == "jdk" })
    }

    @Test func unclaimedRuntimeRemainsVisibleWithoutBorrowingHomebrewEvidence() async throws {
        let fixture = try JavaAttributionFixture()
        let path = try fixture.addRuntime("temurin-27-copy.jdk", version: "27.0.0", receipt: nil)

        let report = await fixture.scanner().scanReport()

        let installation = try #require(report.installations.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) })
        #expect(installation.caskToken == nil)
        #expect(installation.sources.isEmpty)
        #expect(!report.apps.contains { $0.path.pathExtension == "jdk" })
    }

    @Test func versionedMajorsKeepTheirOwnTokensAndHomebrewVersions() async throws {
        let fixture = try JavaAttributionFixture()
        let latest = try fixture.addRuntime("temurin-27.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")
        let lts = try fixture.addRuntime("temurin-21.jdk", version: "21.0.8", receipt: "net.temurin.21.jdk")
        let report = await fixture.scanner().scanReport(brewOutdatedCasks: ["temurin", "temurin@21"])
        let resolved = InstallationCheck.resolvingManagers(
            report.installations, reports: ScanSourceReports(brew: .init(outcome: .succeeded)),
            brew: BrewOutdated(formulae: [], casks: [
                .init(name: "temurin", installedVersions: ["27.0.0"], currentVersion: "27.0.1"),
                .init(name: "temurin@21", installedVersions: ["21.0.8"], currentVersion: "21.0.9"),
            ])
        )

        for (path, token, version) in [(latest, "temurin", "27.0.1"), (lts, "temurin@21", "21.0.9")] {
            let check = try #require(resolved.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) })
            #expect(check.caskToken == token)
            #expect(check.sources == [.init(source: "Homebrew", outcome: .outdated, availableVersion: version, policyKey: "c:" + token)])
        }
        #expect(!report.apps.contains { $0.path.pathExtension == "jdk" })
    }

    @Test func multipleClaimedCopiesCannotShareOneHomebrewResultOrAction() async throws {
        let fixture = try JavaAttributionFixture()
        try fixture.addRuntime("temurin-27.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")
        try fixture.addRuntime("temurin-27-copy.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")

        let report = await fixture.scanner().scanReport()
        let runtimes = report.installations.filter { $0.path.pathExtension == "jdk" }

        #expect(runtimes.count == 2)
        #expect(runtimes.allSatisfy { $0.caskToken == nil && $0.sources.isEmpty })
        #expect(!report.apps.contains { $0.path.pathExtension == "jdk" })
    }

    @Test func ambiguousCaskClaimsLeaveTheRuntimeUnattributed() async throws {
        let fixture = try JavaAttributionFixture()
        try fixture.addRuntime("temurin-27.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")
        try CaskDatabaseCache(fileURL: fixture.cacheURL).save([
            BrewCask(token: "temurin", name: ["Temurin"], pkgutilIdentifiers: ["net.temurin.27.jdk"]),
            BrewCask(token: "temurin@27", name: ["Temurin 27"], pkgutilIdentifiers: ["net.temurin.27.jdk"]),
        ])

        let report = await fixture.scanner().scanReport()
        let runtime = try #require(report.installations.first { $0.path.pathExtension == "jdk" })

        #expect(runtime.caskToken == nil)
        #expect(runtime.sources.isEmpty)
        #expect(!report.apps.contains { $0.path.pathExtension == "jdk" })
    }

    @Test func multipleDistinctReceiptsLeaveTheRuntimeUnattributed() async throws {
        let fixture = try JavaAttributionFixture()
        let path = try fixture.addRuntime("temurin-27.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")
        fixture.runner.receipts[InstallationIdentity(path: path.appendingPathComponent("Contents/Info.plist")).rawValue] =
            "pkgid: net.temurin.27.jdk\n\npkgid: net.temurin.21.jdk\n"

        let report = await fixture.scanner().scanReport()
        let runtime = try #require(report.installations.first { $0.path.pathExtension == "jdk" })

        #expect(runtime.caskToken == nil)
        #expect(runtime.sources.isEmpty)
        #expect(!report.apps.contains { $0.path.pathExtension == "jdk" })
    }

    @Test func symlinkAliasesResolveToOnePhysicalRuntimeAndReceipt() async throws {
        let fixture = try JavaAttributionFixture()
        let path = try fixture.addRuntime("temurin-27.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")
        try FileManager.default.createSymbolicLink(
            at: fixture.runtimes.appendingPathComponent("alias.jdk"), withDestinationURL: path
        )

        let runtimes = JavaRuntimeScanner().scanAll(directories: [fixture.runtimes])
        let report = await fixture.scanner().scanReport()

        #expect(runtimes.count == 1)
        #expect(runtimes.first?.installation == InstallationIdentity(path: path))
        let checks = report.installations.filter { $0.path.pathExtension == "jdk" }
        #expect(checks.count == 1)
        #expect(checks.first?.caskToken == "temurin")
    }

    @Test func versionedCaskCannotClaimARuntimeFromAnotherMajor() async throws {
        let fixture = try JavaAttributionFixture()
        try fixture.addRuntime("temurin-27.jdk", version: "27.0.0", receipt: "net.temurin.21.jdk")

        let report = await fixture.scanner().scanReport()
        let runtime = try #require(report.installations.first { $0.path.pathExtension == "jdk" })

        #expect(runtime.caskToken == nil)
        #expect(runtime.sources.isEmpty)
        #expect(!report.apps.contains { $0.path.pathExtension == "jdk" })
    }

    @Test func ambiguousRuntimeStillPreventsAnotherCopyFromClaimingItsCask() async throws {
        let fixture = try JavaAttributionFixture()
        let ambiguous = try fixture.addRuntime("ambiguous.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")
        fixture.runner.receipts[InstallationIdentity(path: ambiguous.appendingPathComponent("Contents/Info.plist")).rawValue] =
            "pkgid: net.temurin.27.jdk\n\npkgid: net.temurin.21.jdk\n"
        try fixture.addRuntime("temurin-27.jdk", version: "27.0.0", receipt: "net.temurin.27.jdk")

        let report = await fixture.scanner().scanReport()
        let runtimes = report.installations.filter { $0.path.pathExtension == "jdk" }

        #expect(runtimes.count == 2)
        #expect(runtimes.allSatisfy { $0.caskToken == nil && $0.sources.isEmpty })
        #expect(!report.apps.contains { $0.path.pathExtension == "jdk" })
    }
}

private final class JavaAttributionFixture {
    let root: TemporaryDirectory
    let runtimes: URL
    let applications: URL
    let cacheURL: URL
    let runner = JavaAttributionRunner()
    private let defaults: UserDefaults
    private let teardown: () -> Void

    init() throws {
        root = try TemporaryDirectory()
        runtimes = try root.makeSubdirectory("JavaVirtualMachines")
        applications = try root.makeSubdirectory("Applications")
        cacheURL = root.url.appendingPathComponent("casks.json")
        (defaults, teardown) = TestDefaults.isolated("java-installation-attribution")
        try CaskDatabaseCache(fileURL: cacheURL).save([
            BrewCask(token: "temurin", name: ["Eclipse Temurin"], pkgutilIdentifiers: ["net.temurin.27.jdk"]),
            BrewCask(token: "temurin@21", name: ["Eclipse Temurin 21"], pkgutilIdentifiers: ["net.temurin.21.jdk"]),
        ])
    }

    deinit { teardown() }

    func addRuntime(_ name: String, version: String, receipt: String?) throws -> URL {
        let path = try root.makeJDK(named: name, shortVersion: version, in: runtimes)
        if let receipt {
            runner.receipts[InstallationIdentity(path: path.appendingPathComponent("Contents/Info.plist")).rawValue] = "pkgid: \(receipt)\n"
        }
        return path
    }

    func scanner() -> ManualUpdateScanner {
        ManualUpdateScanner(
            brewService: BrewService(
                locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]), runner: runner
            ),
            scanDirectories: [applications], caskCacheURL: cacheURL, maxConcurrentChecks: 1,
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(
                    repo: "coverage/wega", currentVersion: "999.0.0", client: FakeHTTP.client(status: 404)
                ),
                rollbackLedger: CaskRollbackLedger(defaults: defaults),
                javaRuntimeDirectories: [runtimes], packageReceiptLocator: PackageReceiptLocator(runner: runner),
                adobeCatalogClient: AdobeCatalogClient(cache: nil, client: FakeHTTP.client(status: 404)),
                adobeUninstallDirectory: root.url.appendingPathComponent("NoAdobe")
            )
        )
    }
}

private final class JavaAttributionRunner: ProcessRunning, @unchecked Sendable {
    var receipts: [String: String] = [:]

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let output: String
        switch request.arguments {
        case ["list", "--cask", "-1"]:
            output = "temurin\ntemurin@21\n"
        case ["info", "--installed", "--json=v2"]:
            output = #"{"casks":[{"token":"temurin","installed":"27.0.0"},{"token":"temurin@21","installed":"21.0.8"}]}"#
        case let args where args.first == "--file-info":
            output = receipts[InstallationIdentity(path: args.last ?? "").rawValue] ?? ""
        case let args where args.starts(with: ["info", "--cask", "--json=v2"]):
            output = #"{"casks":[{"token":"temurin","version":"27.0.1","artifacts":[{"pkg":["Temurin27.pkg"]}]},{"token":"temurin@21","version":"21.0.9","artifacts":[{"pkg":["Temurin21.pkg"]}]}]}"#
        default:
            return ProcessResult(exitCode: 2, stdout: "", stderr: "Unexpected test arguments")
        }
        return ProcessResult(exitCode: 0, stdout: output, stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
