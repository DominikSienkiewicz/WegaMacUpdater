import XCTest
@testable import MacUpdaterCore

final class ObsidianUpdateCheckerTests: XCTestCase {
    func testBundledEndpointUsesObsidianDesktopReleasesDocument() throws {
        let endpoint = try AppEndpoints.loadBundled().obsidianDesktopReleasesURL
        XCTAssertEqual(endpoint.host, "raw.githubusercontent.com")
        XCTAssertTrue(endpoint.path.hasSuffix("/obsidian-releases/master/desktop-releases.json"))
    }

    func testInsiderUpdateUsesLoadedPackageVersionEvenWhenBrewCaskIsCurrent() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsidian-checker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try #"{"insider":true}"#.write(
            to: applicationSupportDirectory.appendingPathComponent("obsidian.json"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: applicationSupportDirectory.appendingPathComponent("obsidian-1.13.1.asar"))

        let client = FakeHTTP.client(ok: """
        {
          "latestVersion": "1.12.7",
          "beta": { "latestVersion": "1.13.2" }
        }
        """)
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Obsidian.app"),
            name: "Obsidian",
            bundleIdentifier: "md.obsidian",
            version: "1.12.7",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: true,
            caskToken: "obsidian"
        )

        let result = await ObsidianUpdateChecker(
            client: client,
            releasesURL: URL(string: "https://example.test/desktop-releases.json")!,
            applicationSupportDirectory: applicationSupportDirectory
        ).check(app: app)

        guard case .outdated(let update) = result else {
            return XCTFail("expected the Obsidian insider update, got \(result)")
        }
        XCTAssertEqual(update.installedVersion, "1.13.1")
        XCTAssertEqual(update.availableVersion, "1.13.2")
        XCTAssertEqual(update.source, .obsidian)
    }

    func testPublicChannelUsesStableVersionAndFallsBackToBundleVersion() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsidian-checker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try #"{"insider":false}"#.write(
            to: applicationSupportDirectory.appendingPathComponent("obsidian.json"),
            atomically: true,
            encoding: .utf8
        )

        let client = FakeHTTP.client(ok: """
        {
          "latestVersion": "1.12.8",
          "beta": { "latestVersion": "1.13.2" }
        }
        """)
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Obsidian.app"),
            name: "Obsidian",
            bundleIdentifier: "md.obsidian",
            version: "1.12.7",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )

        let result = await ObsidianUpdateChecker(
            client: client,
            releasesURL: URL(string: "https://example.test/desktop-releases.json")!,
            applicationSupportDirectory: applicationSupportDirectory
        ).check(app: app)

        guard case .outdated(let update) = result else {
            return XCTFail("expected the stable Obsidian update, got \(result)")
        }
        XCTAssertEqual(update.installedVersion, "1.12.7")
        XCTAssertEqual(update.availableVersion, "1.12.8")
    }
}
