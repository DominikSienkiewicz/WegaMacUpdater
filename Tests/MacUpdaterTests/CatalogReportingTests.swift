import XCTest
@testable import MacUpdaterCore

/// UX-14 — the reporting layer that decides which scanned apps may be reported to the catalog
/// and turns one into a ``CatalogIssueBuilder``. `AppOrigin.manual` means "installed by hand",
/// **not** "unupdatable": a hand-installed app the catalog already tracks (or that brew/MAS
/// manages) has a known update source and must never surface the report button.
final class CatalogReportingTests: XCTestCase {
    private func app(
        bundleID: String?,
        brew: Bool = false,
        mas: Bool = false,
        version: String? = "1.2.3",
        name: String = "Sample"
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: bundleID,
            version: version,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            isManagedByMas: mas
        )
    }

    func testBrewManagedAppHasKnownSource() {
        XCTAssertTrue(
            CatalogReporting.hasKnownUpdateSource(app(bundleID: "com.x", brew: true), catalog: AppCatalog())
        )
    }

    func testMasManagedAppHasKnownSource() {
        XCTAssertTrue(
            CatalogReporting.hasKnownUpdateSource(app(bundleID: "com.x", mas: true), catalog: AppCatalog())
        )
    }

    func testCatalogTrackedManualAppHasKnownSource() {
        let catalog = AppCatalog(
            github: [GitHubCatalogEntry(bundleId: "com.tracked.app", repo: "owner/repo", caskToken: "tracked")]
        )
        XCTAssertTrue(
            CatalogReporting.hasKnownUpdateSource(app(bundleID: "com.tracked.app"), catalog: catalog)
        )
    }

    func testPlainManualAppNotInCatalogHasNoKnownSource() {
        let catalog = AppCatalog(
            github: [GitHubCatalogEntry(bundleId: "com.other", repo: "owner/repo", caskToken: "other")]
        )
        XCTAssertFalse(
            CatalogReporting.hasKnownUpdateSource(app(bundleID: "com.unknown"), catalog: catalog)
        )
    }

    func testEveryCatalogTableCountsAsKnownSource() {
        let jetbrains = AppCatalog(
            jetbrains: [JetBrainsCatalogEntry(bundleId: "com.jb", code: "IIU", caskToken: "idea")]
        )
        XCTAssertTrue(CatalogReporting.hasKnownUpdateSource(app(bundleID: "com.jb"), catalog: jetbrains))

        let synology = AppCatalog(
            synology: [SynologyCatalogEntry(bundleId: "com.syn", identify: "X", downloadPage: "https://www.synology.com/x")]
        )
        XCTAssertTrue(CatalogReporting.hasKnownUpdateSource(app(bundleID: "com.syn"), catalog: synology))

        let sparkle = AppCatalog(
            sparkleFeedOverrides: [SparkleFeedOverrideEntry(bundleId: "com.spk", feedURL: "https://x.example/appcast.xml")]
        )
        XCTAssertTrue(CatalogReporting.hasKnownUpdateSource(app(bundleID: "com.spk"), catalog: sparkle))
    }

    func testAppWithoutBundleIDIsReportable() {
        XCTAssertFalse(
            CatalogReporting.hasKnownUpdateSource(app(bundleID: nil), catalog: AppCatalog())
        )
    }

    func testIssueBuilderMapsNameBundleIDAndVersion() {
        let builder = CatalogReporting.issueBuilder(for: app(bundleID: "com.acme", version: "3.4.5", name: "Acme"))
        XCTAssertEqual(builder.appName, "Acme")
        XCTAssertEqual(builder.bundleID, "com.acme")
        XCTAssertEqual(builder.versionFormat, "3.4.5")
        XCTAssertNil(builder.feedURL, "ApplicationInfo carries no feed URL, so the builder must leave it nil")
    }

    func testIssueBuilderUsesEmptyBundleIDWhenMissing() {
        let builder = CatalogReporting.issueBuilder(for: app(bundleID: nil, name: "NoID"))
        XCTAssertEqual(builder.bundleID, "")
        XCTAssertEqual(builder.appName, "NoID")
    }
}
