import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

/// A JDK is installed software with an outdated version and a Homebrew cask that can update
/// it, and Wega reported nothing about it: `ApplicationScanner` keeps only `.app` bundles and
/// `AppScanDirectories` never leaves the two Applications roots, so
/// `/Library/Java/JavaVirtualMachines/temurin-26.jdk` was invisible to every checker.
///
/// The suite covers the whole chain that closes that gap — discovery, the installer-receipt
/// bridge to a cask token, and the scan that has to produce the row.
@Suite("Java runtime update detection")
struct JavaRuntimeUpdateDetectionTests {
    // MARK: - Discovery

    @Test func scannerFindsJDKBundlesAndReadsTheirReleaseVersion() throws {
        let root = try TemporaryDirectory()
        try root.makeJDK(named: "temurin-26.jdk", shortVersion: "26.0.1", bundleVersion: "8")

        let runtimes = JavaRuntimeScanner().scan(in: root.url)

        #expect(runtimes.count == 1)
        let runtime = try #require(runtimes.first)
        #expect(runtime.name == "temurin-26.jdk")
        #expect(runtime.version == "26.0.1")
        // `CFBundleVersion` is the build number alone ("8"); handing it to the comparators as
        // an alternative spelling of the release would compare 8 against a cask's 26.0.2.
        #expect(runtime.buildVersion == nil)
    }

    @Test func scannerIgnoresEverythingThatIsNotAJDKBundle() throws {
        let root = try TemporaryDirectory()
        try root.makeJDK(named: "temurin-26.jdk", shortVersion: "26.0.1")
        try FileManager.default.createDirectory(
            at: root.url.appendingPathComponent("Some Folder", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: root.url.appendingPathComponent("notes.txt"))

        #expect(JavaRuntimeScanner().scan(in: root.url).map(\.name) == ["temurin-26.jdk"])
    }

    @Test func scannerFallsBackToTheJavaVMDictionaryWhenTheShortVersionIsMissing() {
        let infoDict: [String: Any] = ["JavaVM": ["JVMVersion": "21.0.8", "JVMPlatformVersion": "21.0.8"]]
        #expect(JavaRuntimeBundle.version(fromInfoDictionary: infoDict) == "21.0.8")
        #expect(JavaRuntimeBundle.version(fromInfoDictionary: [:]) == nil)
    }

    @Test func missingDirectoryIsNoRuntimesRatherThanAnError() {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(JavaRuntimeScanner().scan(in: absent).isEmpty)
    }

    // MARK: - The installer-receipt bridge

    @Test func receiptParserTakesTheFirstPackageIdentifier() {
        let output = """
            volume: /
            path: /Library/Java/JavaVirtualMachines/temurin-26.jdk/Contents/Info.plist

            pkgid: net.temurin.26.jdk
            pkg-version: 26.0.1+8
            install-time: 1779283015
            """
        #expect(PackageReceiptParser.packageIdentifier(fromFileInfo: output) == "net.temurin.26.jdk")
        #expect(PackageReceiptParser.packageIdentifier(fromFileInfo: "volume: /\npath: /tmp/x\n") == nil)
    }

    @Test func caskIndexResolvesAPackageIdentifierToTheCaskThatDeclaresIt() {
        let index = CaskPackageReceiptIndex(casks: [
            BrewCask(token: "temurin", name: ["Eclipse Temurin"], pkgutilIdentifiers: ["net.temurin.26.jdk"]),
            BrewCask(token: "temurin@21", name: ["Eclipse Temurin 21"], pkgutilIdentifiers: ["net.temurin.21.jdk"]),
            BrewCask(token: "firefox", name: ["Firefox"]),
        ])

        #expect(index.token(forPackageIdentifier: "net.temurin.26.jdk") == "temurin")
        #expect(index.token(forPackageIdentifier: "net.temurin.21.jdk") == "temurin@21")
        #expect(index.token(forPackageIdentifier: "com.unknown.pkg") == nil)
    }

    @Test func caskDecodingLiftsReceiptIdentifiersOutOfHomebrewsArtifacts() throws {
        let json = """
            [{
              "token": "temurin",
              "name": ["Eclipse Temurin"],
              "artifacts": [
                {"uninstall": [{"pkgutil": "net.temurin.26.jdk", "launchctl": ["net.temurin.agent"]}]},
                {"pkg": ["OpenJDK26U-jdk_aarch64_mac_hotspot_26.0.2_10.pkg"]},
                {"zap": [{"pkgutil": "net.temurin.*"}]}
              ]
            }]
            """
        let casks = try JSONDecoder().decode([BrewCask].self, from: Data(json.utf8))

        // Only the `uninstall` stanza, and only exact identifiers: a `zap` wildcard would map
        // a whole vendor namespace onto one token and offer the wrong update.
        #expect(casks.first?.pkgutilIdentifiers == ["net.temurin.26.jdk"])
    }

    @Test func caskDecodingToleratesArtifactShapesItDoesNotModel() throws {
        let json = """
            [{
              "token": "weird",
              "name": ["Weird"],
              "artifacts": [
                {"binary": [["nested", "array"]]},
                {"uninstall": [{"pkgutil": ["a.pkg.one", "a.pkg.two"], "quit": "com.weird"}]},
                {"depends_on": {"macos": [">= :sequoia"]}},
                "not-even-an-object"
              ]
            }]
            """
        let casks = try JSONDecoder().decode([BrewCask].self, from: Data(json.utf8))
        #expect(casks.first?.pkgutilIdentifiers == ["a.pkg.one", "a.pkg.two"])
    }

    @Test func aCacheWrittenBeforeReceiptIdentifiersExistedStillDecodes() throws {
        let legacy = Data(#"[{"token":"firefox","name":["Firefox"]}]"#.utf8)
        let casks = try JSONDecoder().decode([BrewCask].self, from: legacy)
        #expect(casks.first?.pkgutilIdentifiers.isEmpty == true)
    }

    @Test func receiptIdentifiersSurviveTheOnDiskCacheRoundTrip() throws {
        let root = try TemporaryDirectory()
        let cache = CaskDatabaseCache(fileURL: root.url.appendingPathComponent("casks.json"))
        try cache.save([BrewCask(token: "temurin", name: ["Eclipse Temurin"],
                                 pkgutilIdentifiers: ["net.temurin.26.jdk"])])

        let reloaded = try #require(try cache.loadIfFresh())
        #expect(reloaded.first?.pkgutilIdentifiers == ["net.temurin.26.jdk"])
    }

    // MARK: - The scan that has to produce the row

    @Test func scanReportsAnOutdatedJDKAsAHomebrewCaskUpdate() async throws {
        let root = try TemporaryDirectory()
        let applications = try root.makeSubdirectory("Applications")
        let runtimes = try root.makeSubdirectory("JavaVirtualMachines")
        let jdkPath = try root.makeJDK(named: "temurin-26.jdk", shortVersion: "26.0.1", in: runtimes)
        let (defaults, teardown) = TestDefaults.isolated("java-runtime-scan")
        defer { teardown() }

        let cacheURL = root.url.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cacheURL).save([
            BrewCask(token: "temurin", name: ["Eclipse Temurin"], pkgutilIdentifiers: ["net.temurin.26.jdk"]),
        ])

        let scanner = ManualUpdateScanner(
            brewService: BrewService(
                locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                runner: TemurinBrewRunner()
            ),
            scanDirectories: [applications],
            caskCacheURL: cacheURL,
            maxConcurrentChecks: 1,
            selfUpdateChecker: WegaSelfUpdateChecker(
                repo: "coverage/wega",
                currentVersion: "999.0.0",
                client: FakeHTTP.client(status: 404)
            ),
            rollbackLedger: CaskRollbackLedger(defaults: defaults),
            javaRuntimeDirectories: [runtimes],
            packageReceiptLocator: PackageReceiptLocator(
                runner: StubProcessRunner(result: ProcessResult(
                    exitCode: 0,
                    stdout: "pkgid: net.temurin.26.jdk\npkg-version: 26.0.1+8\n",
                    stderr: ""
                ))
            ),
            adobeCatalogClient: AdobeCatalogClient(cache: nil, client: FakeHTTP.client(status: 404)),
            adobeUninstallDirectory: try root.makeSubdirectory("NoAdobe")
        )

        let result = await scanner.scan()

        let jdk = try #require(result.apps.first { $0.name == "temurin-26.jdk" })
        #expect(jdk.path.standardizedFileURL.path == jdkPath.standardizedFileURL.path)
        #expect(jdk.installedVersion == "26.0.1")
        // The comma-separated Homebrew build suffix ("26.0.2,10") is presentation noise.
        #expect(jdk.availableVersion == "26.0.2")
        #expect(jdk.source == .cask(token: "temurin"))
    }

    @Test func aRuntimeNoCaskClaimsProducesNoRow() async throws {
        let root = try TemporaryDirectory()
        let applications = try root.makeSubdirectory("Applications")
        let runtimes = try root.makeSubdirectory("JavaVirtualMachines")
        try root.makeJDK(named: "custom-build.jdk", shortVersion: "26.0.1", in: runtimes)
        let (defaults, teardown) = TestDefaults.isolated("java-runtime-scan-unclaimed")
        defer { teardown() }

        let cacheURL = root.url.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cacheURL).save([BrewCask(token: "firefox", name: ["Firefox"])])

        let scanner = ManualUpdateScanner(
            brewService: BrewService(
                locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                runner: TemurinBrewRunner()
            ),
            scanDirectories: [applications],
            caskCacheURL: cacheURL,
            maxConcurrentChecks: 1,
            selfUpdateChecker: WegaSelfUpdateChecker(
                repo: "coverage/wega",
                currentVersion: "999.0.0",
                client: FakeHTTP.client(status: 404)
            ),
            rollbackLedger: CaskRollbackLedger(defaults: defaults),
            javaRuntimeDirectories: [runtimes],
            packageReceiptLocator: PackageReceiptLocator(
                runner: StubProcessRunner(result: ProcessResult(exitCode: 1, stdout: "", stderr: ""))
            ),
            adobeCatalogClient: AdobeCatalogClient(cache: nil, client: FakeHTTP.client(status: 404)),
            adobeUninstallDirectory: try root.makeSubdirectory("NoAdobe")
        )

        #expect(await scanner.scan().apps.isEmpty)
    }
}

/// Answers the three `brew` calls a scan makes, with `temurin` as the only known cask.
private final class TemurinBrewRunner: ProcessRunning, @unchecked Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        switch request.arguments {
        case ["list", "--cask", "-1"]:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case ["info", "--installed", "--json=v2"]:
            return ProcessResult(exitCode: 0, stdout: #"{"casks":[]}"#, stderr: "")
        case let arguments where arguments.starts(with: ["info", "--cask", "--json=v2", "--"]):
            return ProcessResult(
                exitCode: 0,
                stdout: #"{"casks":[{"token":"temurin","version":"26.0.2,10"}]}"#,
                stderr: ""
            )
        default:
            return ProcessResult(exitCode: 2, stdout: "", stderr: "unexpected arguments")
        }
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
