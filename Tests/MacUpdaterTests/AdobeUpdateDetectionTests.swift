import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

/// Adobe ships no Sparkle appcast, no Squirrel feed and — Acrobat Reader aside — no Homebrew
/// cask, so every source the other thirteen checkers use is absent and an outdated Lightroom
/// was reported by nothing at all.
///
/// The suite covers the two halves that close that gap: reading which products Creative Cloud
/// has installed (and their SAP codes) off the machine, and comparing them against Adobe's
/// published product catalog.
@Suite("Adobe update detection")
struct AdobeUpdateDetectionTests {
    // MARK: - Creative Cloud's own inventory

    @Test func argumentFileYieldsTheSapCodeVersionAndProductName() {
        let product = AdobeProductInventory.parse(argumentFile: """
            --sapCode=LRCC
            --productVersion=9.4.1
            --productPlatform=macuniversal
            --productAdobeCode={LRCC-9.4.1-32-ADBEADBEADBEADBEADBEAD}
            --productName=Lightroom
            --mode=2
            """)

        #expect(product == AdobeInstalledProduct(sapCode: "LRCC", version: "9.4.1", productName: "Lightroom"))
    }

    @Test func argumentFileWithoutASapCodeOrVersionIsNotAProduct() {
        #expect(AdobeProductInventory.parse(argumentFile: "--productName=Lightroom\n") == nil)
        #expect(AdobeProductInventory.parse(argumentFile: "--sapCode=LRCC\n") == nil)
        #expect(AdobeProductInventory.parse(argumentFile: "") == nil)
    }

    @Test func inventoryReadsEveryArgumentFileInTheUninstallDirectory() throws {
        let root = try TemporaryDirectory()
        try write("--sapCode=LRCC\n--productVersion=9.4.1\n--productName=Lightroom\n",
                  to: root.url.appendingPathComponent("LRCC_9_4_1_32.adbarg"))
        try write("--sapCode=PHSP\n--productVersion=27.9.1\n--productName=Photoshop\n",
                  to: root.url.appendingPathComponent("PHSP_27_9_1.adbarg"))
        // The uninstaller bundles sit beside the argument files and are not products.
        try root.makeSubdirectory("LRCC_9_4_1_32.app")

        let inventory = AdobeProductInventory.installedProducts(in: root.url)

        #expect(inventory.map(\.sapCode) == ["LRCC", "PHSP"])
    }

    @Test func aMachineWithoutCreativeCloudHasAnEmptyInventory() {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(AdobeProductInventory.installedProducts(in: absent).isEmpty)
    }

    // MARK: - Matching a bundle to a product

    @Test func bundleMatchesTheProductWhoseNameItContainsAtTheSameVersion() {
        let inventory = [
            AdobeInstalledProduct(sapCode: "LRCC", version: "9.4.1", productName: "Lightroom"),
            AdobeInstalledProduct(sapCode: "PHSP", version: "27.9.1", productName: "Photoshop"),
        ]

        let matched = AdobeProductInventory.product(matching: app(named: "Adobe Lightroom", version: "9.4.1"),
                                                    in: inventory)
        #expect(matched?.sapCode == "LRCC")
    }

    /// "Lightroom" is a substring of "Lightroom Classic", so name matching alone would let the
    /// wrong product claim the bundle — and the two are separate products on separate version
    /// lines, so the row would then show a version from the other application entirely.
    @Test func lightroomClassicIsNotClaimedByLightroom() {
        let inventory = [
            AdobeInstalledProduct(sapCode: "LRCC", version: "9.4.1", productName: "Lightroom"),
            AdobeInstalledProduct(sapCode: "LTRM", version: "15.2", productName: "Lightroom Classic"),
        ]

        #expect(AdobeProductInventory.product(
            matching: app(named: "Adobe Lightroom Classic", version: "15.2"), in: inventory
        )?.sapCode == "LTRM")
        #expect(AdobeProductInventory.product(
            matching: app(named: "Adobe Lightroom", version: "9.4.1"), in: inventory
        )?.sapCode == "LRCC")
    }

    @Test func aBundleAtADifferentVersionThanAnyRecordMatchesNothing() {
        let inventory = [AdobeInstalledProduct(sapCode: "LRCC", version: "9.4.1", productName: "Lightroom")]
        #expect(AdobeProductInventory.product(matching: app(named: "Adobe Lightroom", version: "8.0"),
                                              in: inventory) == nil)
        #expect(AdobeProductInventory.product(matching: app(named: "Firefox", version: "9.4.1"),
                                              in: inventory) == nil)
    }

    // MARK: - Adobe's published catalog

    @Test func catalogKeepsTheNewestVersionPerProduct() throws {
        let catalog = try #require(AdobeProductCatalog.parse(xml: Data(Self.catalogXML.utf8)))

        #expect(catalog.latestVersion(forSapCode: "LRCC") == "9.5")
        #expect(catalog.latestVersion(forSapCode: "PHSP") == "27.9.1")
        #expect(catalog.latestVersion(forSapCode: "NOPE") == nil)
    }

    @Test func aBodyThatIsNotTheCatalogIsAFailureRatherThanAnEmptyCatalog() {
        #expect(AdobeProductCatalog.parse(xml: Data("Application Not Authorized.".utf8)) == nil)
        // A well-formed document that lists nothing is a different thing: empty, not broken.
        #expect(AdobeProductCatalog.parse(xml: Data("<response><channels/></response>".utf8))?.isEmpty == true)
    }

    // MARK: - The check

    @Test func anInstalledProductBehindTheCatalogIsOutdated() throws {
        let checker = AdobeUpdateChecker(
            catalog: AdobeProductCatalog(latestVersions: ["LRCC": "9.5"]),
            inventory: [AdobeInstalledProduct(sapCode: "LRCC", version: "9.4.1", productName: "Lightroom")]
        )

        guard case .outdated(let item) = checker.check(app: app(named: "Adobe Lightroom", version: "9.4.1")) else {
            Issue.record("Lightroom 9.4.1 must be reported as outdated against a catalog offering 9.5")
            return
        }
        #expect(item.installedVersion == "9.4.1")
        #expect(item.availableVersion == "9.5")
        #expect(item.source == .adobe(sapCode: "LRCC"))
    }

    @Test func aProductAtTheCatalogVersionIsUpToDate() {
        let checker = AdobeUpdateChecker(
            catalog: AdobeProductCatalog(latestVersions: ["LRCC": "9.5"]),
            inventory: [AdobeInstalledProduct(sapCode: "LRCC", version: "9.5", productName: "Lightroom")]
        )
        #expect(checker.check(app: app(named: "Adobe Lightroom", version: "9.5")) == .upToDate)
    }

    @Test func nonAdobeAppsAndUncataloguedProductsAreNotApplicable() {
        let checker = AdobeUpdateChecker(
            catalog: AdobeProductCatalog(latestVersions: ["LRCC": "9.5"]),
            inventory: [AdobeInstalledProduct(sapCode: "XYZW", version: "1.0", productName: "Retired")]
        )
        #expect(checker.check(app: app(named: "Firefox", version: "9.4.1")) == .notApplicable)
        // Installed but absent from the catalog: nothing is knowable, and nothing is wrong.
        #expect(checker.check(app: app(named: "Adobe Retired", version: "1.0")) == .notApplicable)
    }

    // MARK: - The action offered for the row

    /// The row opens Adobe's *client*, not a web page. Creative Cloud is the only thing that
    /// can install an Adobe update, so a user who has it was being sent the long way round to
    /// an app already sitting on their Mac. The URL survives only as the fallback for a
    /// machine without it.
    @Test func anAdobeRowOpensTheInstalledCreativeCloudClient() {
        let action = ManualOutdatedApp.UpdateSource.adobe(sapCode: "LRCC").updateActionKind
        #expect(action == .creativeCloud(fallbackURL: AppEndpoints.shared.adobeCreativeCloudURL))
    }

    /// Resolution goes through LaunchServices rather than a candidate-path list, because
    /// Creative Cloud does not install into `/Applications`: a stock install puts it at
    /// `/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app`, under a
    /// different name than the folder Adobe leaves in `/Applications`.
    @Test func creativeCloudIsPreferredOverItsLauncherShim() {
        let acc = URL(fileURLWithPath: "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app")
        let shim = URL(fileURLWithPath: "/Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Desktop App.app")
        let installed: [String: URL] = [
            "com.adobe.acc.AdobeCreativeCloud": acc,
            "com.adobe.Creative-Cloud-Desktop-App": shim,
        ]

        // Both present: the client with the Updates list wins.
        #expect(CreativeCloudApplication.resolve { installed[$0] } == acc)
        // Only the shim: reaching the client the long way round still beats a browser.
        #expect(CreativeCloudApplication.resolve { $0 == "com.adobe.Creative-Cloud-Desktop-App" ? shim : nil } == shim)
    }

    @Test func withoutCreativeCloudInstalledThereIsNothingToOpenAndTheRowFallsBack() {
        #expect(CreativeCloudApplication.resolve { _ in nil } == nil)
    }

    /// Where Homebrew also packages a Creative Cloud application, `brew` can apply the update
    /// in place while this source can only point at Creative Cloud — so the cask row has to win
    /// the deduplication.
    @Test func aHomebrewCaskRowOutranksAnAdobeRowForTheSameApp() {
        #expect(ManualOutdatedApp.UpdateSource.cask(token: "adobe-acrobat-reader").priority
                > ManualOutdatedApp.UpdateSource.adobe(sapCode: "APRO").priority)
    }

    // MARK: - The scan that has to produce the row

    @Test func scanReportsAnOutdatedCreativeCloudApp() async throws {
        let root = try TemporaryDirectory()
        let applications = try root.makeSubdirectory("Applications")
        // Lightroom installs into its own folder under /Applications, not directly into it.
        let lightroomFolder = try root.makeSubdirectory("Applications/Adobe Lightroom CC")
        let lightroomPath = try root.makeApp(
            named: "Adobe Lightroom",
            bundleIdentifier: "com.adobe.lightroomCC",
            version: "9.4.1",
            in: lightroomFolder
        )
        let uninstallDirectory = try root.makeSubdirectory("AdobeUninstall")
        try write("--sapCode=LRCC\n--productVersion=9.4.1\n--productName=Lightroom\n",
                  to: uninstallDirectory.appendingPathComponent("LRCC_9_4_1_32.adbarg"))

        let catalogCache = AdobeCatalogCache(fileURL: root.url.appendingPathComponent("adobe.json"))
        try catalogCache.save(AdobeProductCatalog(latestVersions: ["LRCC": "9.5"]))

        let (defaults, teardown) = TestDefaults.isolated("adobe-scan")
        defer { teardown() }

        let scanner = ManualUpdateScanner(
            brewService: BrewService(
                locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                runner: StubProcessRunner(result: ProcessResult(exitCode: 1, stdout: "", stderr: ""))
            ),
            scanDirectories: [applications, lightroomFolder],
            caskCacheURL: root.url.appendingPathComponent("casks.json"),
            maxConcurrentChecks: 1,
            selfUpdateChecker: WegaSelfUpdateChecker(
                repo: "coverage/wega",
                currentVersion: "999.0.0",
                client: FakeHTTP.client(status: 404)
            ),
            rollbackLedger: CaskRollbackLedger(defaults: defaults),
            javaRuntimeDirectories: [],
            packageReceiptLocator: PackageReceiptLocator(
                runner: StubProcessRunner(result: ProcessResult(exitCode: 1, stdout: "", stderr: ""))
            ),
            adobeCatalogClient: AdobeCatalogClient(cache: catalogCache, client: FakeHTTP.client(status: 500)),
            adobeUninstallDirectory: uninstallDirectory
        )

        let result = await scanner.scan()

        let lightroom = try #require(result.apps.first { $0.source == .adobe(sapCode: "LRCC") })
        #expect(lightroom.name == "Adobe Lightroom")
        #expect(lightroom.path.standardizedFileURL.path == lightroomPath.standardizedFileURL.path)
        #expect(lightroom.installedVersion == "9.4.1")
        #expect(lightroom.availableVersion == "9.5")
        #expect(lightroom.bundleIdentifier == "com.adobe.lightroomCC")
    }

    // MARK: - Helpers

    private func app(named name: String, version: String) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: nil,
            version: version,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private static let catalogXML = """
        <?xml version='1.0' encoding='UTF-8'?>
        <response><channels version="1.0"><channel name="ccm"><products>
          <product version="9.4" id="LRCC"><displayName>Lightroom</displayName></product>
          <product version="9.5" id="LRCC"><displayName>Lightroom</displayName></product>
          <product version="9.4.1" id="LRCC"><displayName>Lightroom</displayName></product>
          <product version="27.9.1" id="PHSP"><displayName>Photoshop</displayName></product>
          <product version="27.8" id="PHSP"><displayName>Photoshop</displayName></product>
        </products></channel></channels></response>
        """
}
