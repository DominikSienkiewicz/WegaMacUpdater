import XCTest
@testable import MacUpdaterCore

final class AppCatalogTests: XCTestCase {
    // MARK: Bundled resource loads and matches the data the checkers used to hard-code

    func testBundledCatalogDecodes() throws {
        let catalog = try AppCatalog.loadBundled()
        XCTAssertEqual(catalog.github.count, 12)
        XCTAssertEqual(catalog.jetbrains.count, 14)
        XCTAssertEqual(catalog.synology.count, 1)
        XCTAssertEqual(catalog.sparkleFeedOverrides.count, 1)
    }

    func testGitHubLookupPreservesPreviousMapping() throws {
        let repos = try AppCatalog.loadBundled().githubRepos
        let vscode = repos["com.microsoft.VSCode"]
        XCTAssertEqual(vscode?.repo, "microsoft/vscode")
        XCTAssertEqual(vscode?.caskToken, "visual-studio-code")
        XCTAssertEqual(repos["com.github.GitHubClient"]?.repo, "desktop/desktop")
    }

    func testJetBrainsLookupPreservesPreviousMapping() throws {
        let products = try AppCatalog.loadBundled().jetbrainsProducts
        XCTAssertEqual(products["com.jetbrains.intellij"]?.code, "IIU")
        XCTAssertEqual(products["com.jetbrains.intellij"]?.caskToken, "intellij-idea")
        XCTAssertEqual(products["com.jetbrains.rustrover"]?.code, "RR")
    }

    func testSynologyLookupPreservesPreviousMapping() throws {
        let mapping = try AppCatalog.loadBundled().synologyMappings["com.synology.CloudStation"]
        XCTAssertEqual(mapping?.identify, "SynologyDriveClient")
        XCTAssertEqual(mapping?.downloadPage, "https://www.synology.com/en-global/releaseNote/SynologyDriveClient")
    }

    func testSparkleOverrideMatchesLegacyValue() throws {
        let overrides = try AppCatalog.loadBundled().sparkleFeedOverridesByBundleID
        XCTAssertEqual(overrides["com.openai.codex"], "https://persistent.oaistatic.com/codex-app-prod/appcast.xml")
    }

    /// `SparkleFeedOverrides.defaults` must keep returning the catalog values so the
    /// existing public API (and its test) stays intact after the move to JSON.
    func testSparkleFeedOverridesPublicAPIStillResolves() {
        XCTAssertEqual(
            SparkleFeedOverrides.defaults["com.openai.codex"],
            "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
        )
    }

    // MARK: Overlay semantics — out-of-band catalog updates

    func testOverlayOverridesOnBundleIDCollisionAndAddsNewApps() {
        let base = AppCatalog(github: [
            GitHubCatalogEntry(bundleId: "com.example.app", repo: "old/repo", caskToken: "example"),
        ])
        let overlay = AppCatalog(github: [
            GitHubCatalogEntry(bundleId: "com.example.app", repo: "new/repo", caskToken: "example"),
            GitHubCatalogEntry(bundleId: "com.example.fresh", repo: "fresh/repo", caskToken: "fresh"),
        ])

        let repos = base.overlaying(overlay).githubRepos
        XCTAssertEqual(repos["com.example.app"]?.repo, "new/repo", "overlay must win on collision")
        XCTAssertEqual(repos["com.example.fresh"]?.repo, "fresh/repo", "overlay may introduce new apps")
    }

    // MARK: URL validation at decode time
    //
    // `synology.downloadPage` (and the Sparkle `feedURL`) are opened / fetched verbatim
    // from a file a PR can change — the widest hole for a malicious catalog entry. A
    // non-https or garbage URL must be rejected while decoding, not later at open time.

    func testDecodingRejectsSynologyEntryWithNonHTTPSDownloadPage() {
        let json = Data(#"{"synology":[{"bundleId":"com.x","identify":"X","downloadPage":"http://evil.example/x"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppCatalog.self, from: json))
    }

    func testDecodingRejectsSynologyEntryWithGarbageDownloadPage() {
        let json = Data(#"{"synology":[{"bundleId":"com.x","identify":"X","downloadPage":"javascript:alert(1)"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppCatalog.self, from: json))
    }

    func testDecodingAcceptsSynologyEntryWithHTTPSDownloadPage() throws {
        let json = Data(#"{"synology":[{"bundleId":"com.x","identify":"X","downloadPage":"https://ok.example/x"}]}"#.utf8)
        let catalog = try JSONDecoder().decode(AppCatalog.self, from: json)
        XCTAssertEqual(catalog.synology.first?.downloadPage, "https://ok.example/x")
    }

    func testDecodingRejectsSparkleFeedOverrideWithNonHTTPSFeedURL() {
        let json = Data(#"{"sparkleFeedOverrides":[{"bundleId":"com.x","feedURL":"ftp://evil.example/a.xml"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppCatalog.self, from: json))
    }

    func testDecodingAcceptsSparkleFeedOverrideWithHTTPSFeedURL() throws {
        let json = Data(#"{"sparkleFeedOverrides":[{"bundleId":"com.x","feedURL":"https://ok.example/a.xml"}]}"#.utf8)
        let catalog = try JSONDecoder().decode(AppCatalog.self, from: json)
        XCTAssertEqual(catalog.sparkleFeedOverrides.first?.feedURL, "https://ok.example/a.xml")
    }
}
