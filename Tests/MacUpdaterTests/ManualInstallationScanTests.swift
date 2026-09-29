import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Manual scans identify each installed copy")
struct ManualInstallationScanTests {
    @Test func aCurrentCopyCannotHideAnOlderCopyWithTheSameBundleID() async throws {
        let fixture = try Fixture(versions: ["2.0", "1.0"])
        defer { fixture.remove() }
        let result = await fixture.scanner.scan()
        #expect(result.apps.map { $0.path.path } == [fixture.apps[1].path])
        #expect(result.apps.first?.installedVersion == "1.0")
    }

    @Test func overlappingRootsDoNotDuplicateRowsAndPoliciesStayPerInstallation() async throws {
        let fixture = try Fixture(versions: ["1.0", "1.1"])
        defer { fixture.remove() }
        let result = await fixture.scanner.scan()
        #expect(Set(result.apps.map { $0.path.path }) == Set(fixture.apps.map(\.path)))
        #expect(result.apps.count == 2)
        let first = try #require(result.apps.first { $0.path.path == fixture.apps[0].path })
        let visible = UpdatePlanner.applyPolicies(result.apps, policies: [first.policyKey: .pinned(version: "1.0")])
        #expect(visible.map { $0.path.path } == [fixture.apps[1].path])
    }

    @Test func missingBundleIdentifiersStillUseDistinctPaths() async throws {
        let fixture = try Fixture(versions: ["1.0", "1.1"], bundleID: nil)
        defer { fixture.remove() }
        let result = await fixture.scanner.scan()
        #expect(Set(result.apps.map { $0.path.path }) == Set(fixture.apps.map(\.path)))
        #expect(result.apps.count == 2)
    }

    @Test func anOutdatedCaskSkipsOnlyItsOwnCopy() {
        let paths = ["/Applications/Example.app", "/Users/test/Applications/Example.app"].map { URL(fileURLWithPath: $0) }
        let apps = paths.map {
            ApplicationInfo(path: $0, name: "Example", bundleIdentifier: "com.example.app", version: "1.0",
                            installDate: nil, updateDate: nil, isManagedByBrew: true, caskToken: "example")
        }
        let routed = ManualUpdateScanner.routeDistinctInstallations(
            apps, caskAppPaths: ["example": paths[0]], brewOutdatedCasks: ["example"]
        )
        #expect(routed.map { $0.path.path } == [paths[1].path])
        #expect(routed.first?.caskToken == nil)
        #expect(routed.first?.isManagedByBrew == false)
        let ambiguous = ManualUpdateScanner.routeDistinctInstallations(apps, caskAppPaths: [:], brewOutdatedCasks: [])
        #expect(ambiguous.count == 2)
        #expect(ambiguous.allSatisfy { $0.caskToken == nil })
    }

    private struct Fixture {
        let root: URL
        let apps: [URL]
        let scanner: ManualUpdateScanner

        init(versions: [String], bundleID: String? = "com.example.manual-copy") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let directories = [root.appendingPathComponent("System"), root.appendingPathComponent("User")]
            apps = directories.map { $0.appendingPathComponent("Example.app") }
            for (app, version) in zip(apps, versions) {
                let contents = app.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                var info = ["CFBundleName": "Example", "CFBundleShortVersionString": version,
                            "SUFeedURL": "https://example.invalid/feed.xml"]
                info["CFBundleIdentifier"] = bundleID
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
            }
            let cache = root.appendingPathComponent("casks.json")
            try CaskDatabaseCache(fileURL: cache).save([])
            let feed = #"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure sparkle:version="2.0" url="https://example.invalid/Example.zip"/></item></channel></rss>"#
            let transport = FakeHTTPTransport(Array(repeating: .success(.init(data: Data(feed.utf8), status: 200, headers: [:])), count: 2))
            scanner = ManualUpdateScanner(
                brewService: BrewService(
                    locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                    runner: EmptyInstallationBrewRunner()
                ),
                scanDirectories: directories + [directories[0]], caskCacheURL: cache,
                selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(status: 503)),
                javaRuntimeDirectories: [], adobeUninstallDirectory: root.appendingPathComponent("no-adobe"),
                sparkleChecker: SparkleUpdateChecker(client: HTTPClient(transport: transport, maxRetries: 0), feedOverrides: [:])
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private struct EmptyInstallationBrewRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: request.arguments.first == "list" ? "" : "{\"casks\":[]}", stderr: "")
    }
    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
