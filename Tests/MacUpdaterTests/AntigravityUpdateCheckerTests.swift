import XCTest
@testable import MacUpdaterCore

final class AntigravityUpdateCheckerTests: XCTestCase {

    // Real shape of the Antigravity update API response
    // (`…/api/update/darwin-arm64/stable/latest`). The Antigravity *product*
    // version (2.0.1) lives ONLY in the download URL path — the `name` /
    // `productVersion` fields carry the underlying VS Code base version
    // (1.107.0), which must NOT be used for the update comparison.
    private let sampleJSON = """
    {
        "timestamp": 1779174861,
        "supportsFastUpdate": true,
        "version": "bf9a033f33934fb4496d7eebed52486272437c3a",
        "ideVersion": "Antigravity IDE",
        "productVersion": "1.107.0",
        "name": "1.107.0",
        "hash": "84ec2710254ff4a695498fe1077c12ae164163fb",
        "url": "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.0.1-4861014005645312/darwin-arm/Antigravity IDE.zip",
        "displayName": "macOS for Apple Silicon (.zip)"
    }
    """

    func testProductVersionExtractsAntigravityVersionFromUpdateJSON() {
        let data = Data(sampleJSON.utf8)
        XCTAssertEqual(AntigravityUpdateParser.productVersion(fromUpdateJSON: data), "2.0.1")
    }

    // Guard against the easy mistake of reading `name` / `productVersion`,
    // which would yield the wrong number (the VS Code base, 1.107.0).
    func testProductVersionIgnoresVSCodeBaseVersionFields() {
        let data = Data(sampleJSON.utf8)
        XCTAssertNotEqual(AntigravityUpdateParser.productVersion(fromUpdateJSON: data), "1.107.0")
    }

    func testProductVersionExtractsFromDownloadURLDirectly() {
        let url = "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.0.1-4861014005645312/darwin-arm/Antigravity IDE.zip"
        XCTAssertEqual(AntigravityUpdateParser.productVersion(fromDownloadURL: url), "2.0.1")
    }

    func testProductVersionReturnsNilForMalformedJSON() {
        XCTAssertNil(AntigravityUpdateParser.productVersion(fromUpdateJSON: Data("not json".utf8)))
    }

    func testProductVersionReturnsNilWhenURLHasNoStableSegment() {
        XCTAssertNil(AntigravityUpdateParser.productVersion(fromDownloadURL: "https://example.com/foo/bar.zip"))
    }

    // End-to-end reproduction of the reported bug: the real API payload yields
    // 2.0.1, which is strictly newer than the installed 2.0.0 — so Wega must
    // be able to flag antigravity as outdated.
    func testInstalledVersionIsDetectedAsOutdatedAgainstLatest() {
        let latest = AntigravityUpdateParser.productVersion(fromUpdateJSON: Data(sampleJSON.utf8))
        XCTAssertNotNil(latest)
        XCTAssertTrue(isUpgrade(installed: "2.0.0", latest: latest ?? ""))
    }
}
