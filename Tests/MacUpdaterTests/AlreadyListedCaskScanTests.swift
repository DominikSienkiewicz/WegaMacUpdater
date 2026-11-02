import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

@Suite("Already listed casks keep independent vendor checks")
struct AlreadyListedCaskScanTests {
    @Test(arguments: [false, true], [false, true])
    func listedCasksSkipFallbackWithoutSuppressingVendorEvidence(alreadyListed: Bool, caskVersionAvailable: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, teardown) = TestDefaults.isolated("AlreadyListedCaskScanTests")
        defer { teardown() }
        let vendorPath = try makeApp(named: "Vendor", in: root, hasFeed: true)
        let candidatePath = try makeApp(named: "Candidate", in: root, hasFeed: false)
        let cache = root.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cache).save([
            BrewCask(token: "vendor", name: ["Vendor"]),
            BrewCask(token: "candidate", name: ["Candidate"]),
        ])
        let runner = AlreadyListedCaskRunner(vendorVersionAvailable: caskVersionAvailable)
        let scanner = ManualUpdateScanner(
            brewService: BrewService(
                locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                runner: runner
            ),
            scanDirectories: [root], caskCacheURL: cache, maxConcurrentChecks: 1,
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(ok: #"{"tag_name":"0.0.0","draft":false,"prerelease":false}"#)),
                rollbackLedger: CaskRollbackLedger(defaults: defaults), javaRuntimeDirectories: [],
                adobeUninstallDirectory: root.appendingPathComponent("no-adobe"),
                sparkleChecker: SparkleUpdateChecker(client: FakeHTTP.client(ok: Self.appcast), feedOverrides: [:]),
                vendorClient: FakeHTTP.client(status: 503)
            )
        )

        let report = await scanner.scanReport(brewOutdatedCasks: alreadyListed ? ["vendor"] : [])

        let missingRequiredVersion = !alreadyListed && !caskVersionAvailable
        #expect(report.failedChecks == (missingRequiredVersion ? 1 : 0))
        #expect(report.uncheckedSources == (missingRequiredVersion ? ["Cask · Vendor"] : []))
        #expect(runner.latestVersionRequestCount == 1)
        #expect(runner.latestVersionTokens == (alreadyListed ? ["candidate"] : ["candidate", "vendor"]))
        let vendor = try #require(report.apps.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: vendorPath) })
        #expect(vendor.availableVersion == "3.0")
        #expect(vendor.source.badgeLabel == "Sparkle")
        let candidate = try #require(report.apps.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: candidatePath) })
        #expect(candidate.availableVersion == "2.0")
        #expect(candidate.source == .cask(token: "candidate"))
        #expect(report.apps.count == 2)
        let evidence = try #require(report.installations.first { InstallationIdentity(path: $0.path) == InstallationIdentity(path: vendorPath) })
        #expect(evidence.sources.contains { $0.source == "Sparkle" && $0.outcome == .outdated })
        #expect(evidence.sources.contains { $0.source == "Cask" } == !alreadyListed)
    }

    private static let appcast = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
          <enclosure url="https://example.invalid/vendor.zip" sparkle:version="3.0" sparkle:shortVersionString="3.0"/>
        </item></channel></rss>
        """

    private func makeApp(named name: String, in root: URL, hasFeed: Bool) throws -> URL {
        let app = root.appendingPathComponent(name + ".app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = ["CFBundleName": name, "CFBundleIdentifier": "com.example.listed-cask.\(name.lowercased())",
                     "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1.0"]
        if hasFeed { plist["SUFeedURL"] = "https://example.invalid/appcast.xml" }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}

private final class AlreadyListedCaskRunner: ProcessRunning, @unchecked Sendable {
    private let vendorVersionAvailable: Bool
    private let lock = NSLock()
    private var tokens: Set<String> = []
    private var requestCount = 0
    var latestVersionTokens: Set<String> { lock.withLock { tokens } }
    var latestVersionRequestCount: Int { lock.withLock { requestCount } }

    init(vendorVersionAvailable: Bool) {
        self.vendorVersionAvailable = vendorVersionAvailable
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let output: String
        switch request.arguments {
        case ["list", "--cask", "-1"]:
            output = ""
        case ["info", "--installed", "--json=v2"]:
            output = #"{"casks":[]}"#
        case let arguments where arguments.starts(with: ["info", "--cask", "--json=v2", "--"]):
            lock.withLock {
                tokens.formUnion(arguments.dropFirst(4))
                requestCount += 1
            }
            output = vendorVersionAvailable
                ? #"{"casks":[{"token":"candidate","version":"2.0"},{"token":"vendor","version":"2.0"}]}"#
                : #"{"casks":[{"token":"candidate","version":"2.0"}]}"#
        default:
            Issue.record("Unexpected process request: \(request.arguments)")
            output = "{}"
        }
        return ProcessResult(exitCode: 0, stdout: output, stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
