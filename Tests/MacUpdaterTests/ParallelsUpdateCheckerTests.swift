import XCTest
@testable import MacUpdaterCore

final class ParallelsUpdateCheckerTests: XCTestCase {

    // Trimmed real payload from
    // https://update.parallels.com/desktop/v26/parallels/parallels_updates.xml
    // captured 2026-05-30. The latest available build for the 26 line is
    // 26.3.3 (build 57507); the user runs 26.3.2 (build 57398).
    private let sampleXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ParallelsUpdates schemaVersion="1.0">
        <Product>
            <ProductName>Parallels Desktop</ProductName>
            <UpdateEnabled>1</UpdateEnabled>
                <Version>
                <Major>26</Major>
                <Minor>3</Minor>
                <SubMinor>3</SubMinor>
                <SubSubMinor>57507</SubSubMinor>
                <StringRepresentation>Sumer</StringRepresentation>
                <Update uuid="desktop.26.3.3.57507.en_US.parallels.mac">
                    <FilePath>https://download.parallels.com/desktop/v26/26.3.3-57507/ParallelsDesktop-26.3.3-57507.dmg</FilePath>
                </Update>
            </Version>
        </Product>
    </ParallelsUpdates>
    """

    func testLatestVersionExtractsMajorMinorSubMinor() {
        let result = ParallelsUpdateParser.latest(fromUpdatesXML: Data(sampleXML.utf8))
        XCTAssertEqual(result?.shortVersion, "26.3.3")
    }

    func testLatestVersionExtractsBuildFromSubSubMinor() {
        let result = ParallelsUpdateParser.latest(fromUpdatesXML: Data(sampleXML.utf8))
        XCTAssertEqual(result?.build, "57507")
    }

    func testReportedInstalledIsDetectedAsOutdatedAgainstLatest() {
        let latest = ParallelsUpdateParser.latest(fromUpdatesXML: Data(sampleXML.utf8))!
        // Real-world reproduction: 26.3.2 installed, 26.3.3 available upstream
        // while Homebrew cask `parallels` still reports 26.3.2.
        XCTAssertTrue(isUpgrade(installed: "26.3.2", latest: latest.shortVersion))
    }

    func testLatestVersionReturnsNilForMalformedXML() {
        XCTAssertNil(ParallelsUpdateParser.latest(fromUpdatesXML: Data("not xml".utf8)))
    }

    func testLatestVersionReturnsNilWhenVersionElementMissing() {
        let xml = "<ParallelsUpdates><Product><ProductName>Parallels Desktop</ProductName></Product></ParallelsUpdates>"
        XCTAssertNil(ParallelsUpdateParser.latest(fromUpdatesXML: Data(xml.utf8)))
    }

    // The vendor groups updates per major (v20, v26, …). The checker must
    // derive the right endpoint from the installed major so a Parallels 26
    // user is not silently queried against the v20 feed.
    func testUpdateURLDerivesFromInstalledMajor() {
        let url = ParallelsUpdateChecker.updateURL(forShortVersion: "26.3.2")
        XCTAssertEqual(url?.absoluteString,
                       "https://update.parallels.com/desktop/v26/parallels/parallels_updates.xml")
    }

    func testUpdateURLReturnsNilForUnparseableVersion() {
        XCTAssertNil(ParallelsUpdateChecker.updateURL(forShortVersion: ""))
        XCTAssertNil(ParallelsUpdateChecker.updateURL(forShortVersion: "abc"))
    }

    func testCheckerTargetsParallelsDesktopBundleIdentifier() {
        XCTAssertEqual(ParallelsUpdateChecker.bundleIdentifier, "com.parallels.desktop.console")
    }
}
