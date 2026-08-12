import WegaTestSupport
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

    // MARK: GitHub catalog entry selfUpdates field

    /// Katalog jest podpisany i pobierany zdalnie, więc dokument starszej generacji, który
    /// nie zna tego pola, musi nadal dekodować się poprawnie. Domyślka „nie" znaczy też, że
    /// nowy wpis nie obiecuje uruchomienia, które niczego nie zrobi.
    func testSelfUpdatesDefaultsToFalseWhenTheKeyIsAbsent() throws {
        let json = Data("""
        {"github":[{"bundleId":"com.example.App","repo":"o/r","caskToken":"app"}]}
        """.utf8)

        let entry = try XCTUnwrap(AppCatalog.decode(json).githubRepos["com.example.App"])

        XCTAssertFalse(entry.selfUpdates)
    }

    func testSelfUpdatesIsCarriedWhenDeclared() throws {
        let json = Data("""
        {"github":[{"bundleId":"com.example.App","repo":"o/r","caskToken":"app","selfUpdates":true}]}
        """.utf8)

        let entry = try XCTUnwrap(AppCatalog.decode(json).githubRepos["com.example.App"])

        XCTAssertTrue(entry.selfUpdates)
    }

    // MARK: Overlay generation guard — a stale overlay must not shadow the build
    //
    // Zgłoszone 2026-08-12: flaga `selfUpdates` pojechała w buildzie generacji 3, a overlay
    // generacji 1 sprzed istnienia tego klucza dalej zasłaniał wpis VS Code — akcja została
    // „GitHub Releases" zamiast „Otwórz aplikację", bo `selfUpdates` zdekodowało się do
    // domyślnego `false`.

    func testStaleOverlayDoesNotShadowTheBundledCatalog() throws {
        let bundled = AppCatalog(
            generation: 3,
            github: [GitHubCatalogEntry(
                bundleId: "com.microsoft.VSCode",
                repo: "microsoft/vscode",
                caskToken: "visual-studio-code",
                selfUpdates: true
            )]
        )
        let overlay = AppCatalog(
            generation: 1,
            github: [GitHubCatalogEntry(
                bundleId: "com.microsoft.VSCode",
                repo: "microsoft/vscode",
                caskToken: "visual-studio-code"
            )]
        )

        let entry = try XCTUnwrap(
            AppCatalog.resolve(bundled: bundled, overlay: overlay).githubRepos["com.microsoft.VSCode"]
        )

        XCTAssertTrue(entry.selfUpdates, "overlay starszej generacji nie może zasłonić builda")
    }

    /// Overlay starszej generacji jest odrzucany **w całości, każda sekcja** — nie tylko
    /// `github` — bo generacja opisuje publikację, nie pojedynczy wpis, więc mieszanie
    /// dałoby katalog, dla którego żadna generacja nie jest prawdziwa.
    func testStaleOverlayIsRejectedWholesaleIncludingItsNewApps() {
        let bundled = AppCatalog(generation: 3)
        let overlay = AppCatalog(
            generation: 1,
            github: [GitHubCatalogEntry(bundleId: "com.example.fresh", repo: "fresh/repo", caskToken: "fresh")],
            synology: [SynologyCatalogEntry(
                bundleId: "com.example.freshSynology", identify: "Fresh", downloadPage: "https://example.com/fresh"
            )],
            sparkleFeedOverrides: [SparkleFeedOverrideEntry(
                bundleId: "com.example.freshSparkle", feedURL: "https://example.com/fresh.xml"
            )]
        )

        let resolved = AppCatalog.resolve(bundled: bundled, overlay: overlay)

        XCTAssertNil(resolved.githubRepos["com.example.fresh"])
        XCTAssertNil(resolved.synologyMappings["com.example.freshSynology"])
        XCTAssertNil(resolved.sparkleFeedOverridesByBundleID["com.example.freshSparkle"])
        XCTAssertEqual(resolved.generation, 3)
    }

    /// Kopia OTA tej samej publikacji to normalny stan, nie atak — równość musi przechodzić.
    func testOverlayOfEqualGenerationStillApplies() {
        let bundled = AppCatalog(generation: 3)
        let overlay = AppCatalog(
            generation: 3,
            github: [GitHubCatalogEntry(bundleId: "com.example.fresh", repo: "fresh/repo", caskToken: "fresh")]
        )

        let resolved = AppCatalog.resolve(bundled: bundled, overlay: overlay)

        XCTAssertEqual(resolved.githubRepos["com.example.fresh"]?.repo, "fresh/repo")
    }

    func testNewerOverlayStillWinsOnCollisionAndSetsTheMergedGeneration() {
        let bundled = AppCatalog(
            generation: 3,
            github: [GitHubCatalogEntry(bundleId: "com.example.app", repo: "old/repo", caskToken: "example")]
        )
        let overlay = AppCatalog(
            generation: 4,
            github: [GitHubCatalogEntry(bundleId: "com.example.app", repo: "new/repo", caskToken: "example")]
        )

        let resolved = AppCatalog.resolve(bundled: bundled, overlay: overlay)

        XCTAssertEqual(resolved.githubRepos["com.example.app"]?.repo, "new/repo")
        XCTAssertEqual(resolved.generation, 4, "scalony katalog raportuje generację danych w użyciu")
    }

    /// Katalog z builda niesie generację, przeciw której mierzy się każdy overlay.
    func testBundledGenerationMatchesTheShippedCatalog() throws {
        XCTAssertEqual(AppCatalog.bundledGeneration, try AppCatalog.loadBundled().generation)
    }

    // MARK: Ledger floor — the build's own generation is a floor under the OTA watermark

    func testLedgerRefusesACatalogBelowTheFloor() {
        let (defaults, teardown) = TestDefaults.isolated("catalog-generation-floor")
        defer { teardown() }
        let ledger = CatalogGenerationLedger(defaults: defaults, floor: 3)

        XCTAssertFalse(ledger.accepts(2))
        XCTAssertTrue(ledger.accepts(3), "równa generacja jest normalna, nie atak")
        XCTAssertTrue(ledger.accepts(4))
    }

    /// Bez podłogi rejestr zachowuje się jak dotąd, więc istniejące wstrzyknięcia nie zmieniają
    /// znaczenia.
    func testLedgerWithoutAFloorAcceptsFromZero() {
        let (defaults, teardown) = TestDefaults.isolated("catalog-generation-no-floor")
        defer { teardown() }
        let ledger = CatalogGenerationLedger(defaults: defaults)

        XCTAssertTrue(ledger.accepts(0))
        XCTAssertEqual(ledger.accepted, 0)
    }

    /// `record` mierzy się z wartością zapisaną w `UserDefaults`, nie z `accepted` — podłoga
    /// jest klamrą tylko po stronie odczytu. Gdyby `record` porównywał się z `accepted`, każde
    /// pobranie katalogu o generacji równej podłodze — normalny przypadek, bo wydanie wysyła
    /// build z katalogiem, który samo właśnie opublikowało — byłoby cichym no-opem, a znak
    /// wodny zostałby na `0`. Instalacja byłaby wtedy chroniona wyłącznie przez to, jaki build
    /// akurat działa: downgrade do starszego builda zniósłby podłogę i odsłonił generacje
    /// pomiędzy. Zapisując realnie odebraną generację nawet na podłodze, znak wodny OTA
    /// chroni instalację niezależnie od tego, który build jest uruchomiony.
    func testRecordingPersistsAGenerationThatArrivedOverTheAirEvenAtTheFloor() {
        let (defaults, teardown) = TestDefaults.isolated("catalog-generation-floor-record")
        defer { teardown() }
        let ledger = CatalogGenerationLedger(defaults: defaults, floor: 3)

        ledger.record(3)

        XCTAssertEqual(defaults.integer(forKey: CatalogGenerationLedger.defaultsKey), 3)
        XCTAssertEqual(ledger.accepted, 3)
    }

    func testRecordingAboveTheFloorPersists() {
        let (defaults, teardown) = TestDefaults.isolated("catalog-generation-above-floor")
        defer { teardown() }
        let ledger = CatalogGenerationLedger(defaults: defaults, floor: 3)

        ledger.record(5)

        XCTAssertEqual(defaults.integer(forKey: CatalogGenerationLedger.defaultsKey), 5)
        XCTAssertEqual(ledger.accepted, 5)
    }
}
