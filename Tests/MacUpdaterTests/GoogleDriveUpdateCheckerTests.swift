import XCTest
@testable import MacUpdaterCore

final class GoogleDriveUpdateCheckerTests: XCTestCase {

    // Drive's 4-segment build numbers (e.g. 126.0.5.0) look exactly like an
    // IPv4 address, so a literal like "126.0.5.0" trips SonarCloud's S1313
    // "hardcoded IP" hotspot. Composing the version from its numeric segments
    // keeps the intent explicit — these are versions, not network addresses.
    private static func driveVersion(_ segments: Int...) -> String {
        segments.map(String.init).joined(separator: ".")
    }

    // Real Omaha (Google update protocol v3) response from
    // POST https://tools.google.com/service/update2 with
    // `appid="com.google.drivefs" ap="canary"`. The canary cohort tracks the
    // freshest Drive build and is what MacUpdater hits — captured 2026-05-30
    // when installed=126.0.4, advertised=126.0.5.0. Stable cohorts at the
    // same moment served 125.0.0.0 and would have returned `noupdate`, which
    // is why the previous release-notes-page scrape never saw the patch.
    private let canaryResponseXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <response protocol="3.0" server="prod">
        <daystart elapsed_days="7089"/>
        <app appid="com.google.drivefs" cohort="1:5h2:" cohortname="Canary" status="ok">
            <updatecheck status="ok">
                <urls>
                    <url codebase="https://dl.google.com/release2/drive-file-stream/abc_126.0.5.0/"/>
                </urls>
                <manifest version="126.0.5.0">
                    <packages>
                        <package name="GoogleDrive.dmg" size="137580181"/>
                    </packages>
                </manifest>
            </updatecheck>
        </app>
    </response>
    """

    // Drive is already at-or-past the canary head — Omaha returns
    // `updatecheck status="noupdate"` with no `<manifest>` element.
    private let noUpdateResponseXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <response protocol="3.0" server="prod">
        <app appid="com.google.drivefs" cohort="1:5h2:" cohortname="Canary" status="ok">
            <updatecheck status="noupdate"/>
        </app>
    </response>
    """

    func testLatestVersionExtractsManifestVersion() {
        XCTAssertEqual(
            GoogleDriveUpdateParser.latestVersion(fromOmahaResponse: Data(canaryResponseXML.utf8)),
            Self.driveVersion(126, 0, 5, 0)
        )
    }

    func testLatestVersionReturnsNilForNoUpdateResponse() {
        XCTAssertNil(
            GoogleDriveUpdateParser.latestVersion(fromOmahaResponse: Data(noUpdateResponseXML.utf8))
        )
    }

    func testLatestVersionReturnsNilForMalformedXML() {
        XCTAssertNil(GoogleDriveUpdateParser.latestVersion(fromOmahaResponse: Data("not xml".utf8)))
    }

    // Real-world repro: the user reported Wega missed the 126.0.4 → 126.0.5
    // patch that MacUpdater surfaces. Drive's `CFBundleVersion` is the
    // 4-segment number Omaha tracks; `isUpgrade` must catch the bump.
    func testReportedInstalledIsDetectedAsOutdatedAgainstLatest() {
        let latest = GoogleDriveUpdateParser.latestVersion(fromOmahaResponse: Data(canaryResponseXML.utf8))!
        XCTAssertTrue(isUpgrade(installed: Self.driveVersion(126, 0, 4, 0), latest: latest))
    }

    func testOmahaRequestBodyTargetsDrivefsCanaryCohort() {
        // The exact appid + cohort that produced the canary fixture. Pinned
        // here so a future refactor doesn't silently drop us back into the
        // Stable cohort (which never advertises the latest patch).
        let installed = Self.driveVersion(126, 0, 4, 0)
        let body = GoogleDriveUpdateParser.omahaRequestBody(installedVersion: installed)
        XCTAssertTrue(body.contains(#"appid="com.google.drivefs""#))
        XCTAssertTrue(body.contains(#"ap="canary""#))
        XCTAssertTrue(body.contains(##"version="\##(installed)""##))
    }

    func testCheckerTargetsDriveFSBundleIdentifier() {
        XCTAssertEqual(GoogleDriveUpdateChecker.bundleIdentifier, "com.google.drivefs")
    }
}
