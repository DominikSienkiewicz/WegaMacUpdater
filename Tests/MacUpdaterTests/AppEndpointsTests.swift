import XCTest
@testable import MacUpdaterCore

final class AppEndpointsTests: XCTestCase {
    // MARK: Bundled resource loads and the shared accessor resolves

    func testBundledEndpointsDecode() throws {
        let endpoints = try AppEndpoints.loadBundled()
        XCTAssertFalse(endpoints.googleDriveOmaha.isEmpty)
        XCTAssertFalse(endpoints.caskDatabase.isEmpty)
    }

    func testSharedResolvesWithoutCrashing() {
        // `shared` fatal-errors if the bundled resource is missing/malformed,
        // so simply touching it exercises the launch-time contract.
        XCTAssertNotNil(AppEndpoints.shared.googleDriveOmahaURL.scheme)
    }

    // The CatalogRefresher source endpoint must be present in the bundled config
    // (the launch-time refresh + the Info "Odśwież katalog" button both read it).
    func testAppCatalogEndpointIsConfigured() throws {
        let e = try AppEndpoints.loadBundled()
        XCTAssertEqual(e.appCatalogURL.scheme, "https")
        XCTAssertTrue(e.appCatalog.hasSuffix("app-catalog.json"),
                      "catalog source should point at an app-catalog.json document")
    }

    // MARK: Fixed endpoints keep the exact URLs the checkers used to hard-code

    func testFixedEndpointsMatchLegacyValues() throws {
        let e = try AppEndpoints.loadBundled()
        XCTAssertEqual(e.chatgptAppcastURL.absoluteString,
                       "https://persistent.oaistatic.com/sidekick/public/sparkle_public_appcast.xml")
        XCTAssertEqual(e.googleDriveOmahaURL.absoluteString,
                       "https://tools.google.com/service/update2")
        XCTAssertEqual(e.caskDatabaseURL.absoluteString,
                       "https://formulae.brew.sh/api/cask.json")
        XCTAssertEqual(e.homebrewWebsiteURL.absoluteString, "https://brew.sh")
        XCTAssertEqual(e.googleDriveDownloadURL.absoluteString,
                       "https://www.google.com/drive/download/")
        XCTAssertEqual(e.projectRepositoryURL.absoluteString,
                       "https://github.com/DominikSienkiewicz/WegaMacUpdater")
        XCTAssertEqual(e.projectIssuesURL.absoluteString,
                       "https://github.com/DominikSienkiewicz/WegaMacUpdater/issues")
        XCTAssertEqual(e.authorLinkedInURL.absoluteString,
                       "https://www.linkedin.com/in/dominik-sienkiewicz/")
        XCTAssertEqual(e.masRepositoryURL.absoluteString, "https://github.com/mas-cli/mas")
        XCTAssertEqual(e.signalUpdateURL.absoluteString,
                       "https://updates.signal.org/desktop/latest-mac.yml")
        XCTAssertEqual(e.homebrewInstallCommand,
                       #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#)
    }

    // MARK: Templated endpoints substitute placeholders into the legacy URLs

    func testTemplatedEndpointsFillPlaceholders() throws {
        let e = try AppEndpoints.loadBundled()
        XCTAssertEqual(e.jetbrainsReleasesURL(code: "IIU")?.absoluteString,
                       "https://data.services.jetbrains.com/products/releases?code=IIU&latest=true&type=release")
        XCTAssertEqual(e.githubLatestReleaseURL(repo: "microsoft/vscode")?.absoluteString,
                       "https://api.github.com/repos/microsoft/vscode/releases/latest")
        XCTAssertEqual(e.synologyChangeLogURL(identify: "SynologyDriveClient")?.absoluteString,
                       "https://www.synology.com/api/releaseNote/findChangeLog?identify=SynologyDriveClient&lang=enu")
        XCTAssertEqual(e.antigravityUpdateURL(platform: "darwin-arm64")?.absoluteString,
                       "https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/api/update/darwin-arm64/stable/latest")
        XCTAssertEqual(e.parallelsUpdatesURL(major: 26)?.absoluteString,
                       "https://update.parallels.com/desktop/v26/parallels/parallels_updates.xml")
        XCTAssertEqual(e.postmanUpdateURL(version: "12.15.6")?.absoluteString,
                       "https://dl.pstmn.io/update/osx_64/12.15.6")
        XCTAssertEqual(e.discordUpdateURL(channel: "canary", version: "0.0.966")?.absoluteString,
                       "https://discord.com/api/updates/canary?platform=osx&version=0.0.966")
        XCTAssertEqual(e.chromeVersionsURL(channel: "canary")?.absoluteString,
                       "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/canary/versions")
        XCTAssertEqual(e.githubReleasesPageURL(repo: "owner/app")?.absoluteString,
                       "https://github.com/owner/app/releases/latest")
    }

    // MARK: Overlay semantics — a user file may redirect a single endpoint

    func testOverlayOverridesOnlyTheProvidedKey() throws {
        let base = try AppEndpoints.loadBundled()
        let overlay = AppEndpointsOverlay(
            jetbrainsReleases: nil,
            chatgptAppcast: nil,
            googleDriveOmaha: "https://example.test/omaha",
            caskDatabase: nil,
            appCatalog: nil,
            githubLatestRelease: nil,
            synologyChangeLog: nil,
            antigravityUpdate: nil,
            parallelsUpdates: nil,
            postmanUpdate: nil,
            discordUpdate: nil,
            signalUpdate: nil,
            chromeVersions: nil,
            homebrewWebsite: nil,
            homebrewInstallCommand: nil,
            githubReleasesPage: nil,
            googleDriveDownload: nil,
            projectRepository: nil,
            projectIssues: nil,
            authorLinkedIn: nil,
            masRepository: nil
        )
        let merged = base.overlaying(overlay)
        XCTAssertEqual(merged.googleDriveOmaha, "https://example.test/omaha", "overlay key must win")
        XCTAssertEqual(merged.caskDatabase, base.caskDatabase, "untouched keys keep the baseline")
    }

    // MARK: Overlay decoded from a file on disk (the user-writable redirect file)

    func testDecodeOverlayFromFileReadsOnlyProvidedKeys() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-overlay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"googleDriveOmaha":"https://example.test/omaha"}"#
            .write(to: tmp, atomically: true, encoding: .utf8)

        let overlay = try AppEndpoints.decodeOverlay(contentsOf: tmp)
        XCTAssertEqual(overlay.googleDriveOmaha, "https://example.test/omaha")
        XCTAssertNil(overlay.caskDatabase, "keys absent from the file decode to nil so the baseline shows through")

        // End-to-end: an on-disk overlay redirects exactly one endpoint.
        let merged = try AppEndpoints.loadBundled().overlaying(overlay)
        XCTAssertEqual(merged.googleDriveOmaha, "https://example.test/omaha")
    }

    func testDecodeOverlayRejectsMalformedFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-overlay-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "not valid json".write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AppEndpoints.decodeOverlay(contentsOf: tmp))
    }
}
