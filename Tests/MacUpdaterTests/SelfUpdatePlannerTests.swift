import XCTest
@testable import MacUpdaterCore

/// UX-06 — "Pobierz i zainstaluj" must not label an operation that in fact only downloads
/// and opens an installer. The plan decides which of the two the button is about to do, so
/// the label and the messaging can be honest about `download`/`open` vs `install`.
final class SelfUpdatePlannerTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    func testPkgWithHelperInstallsSilently() {
        XCTAssertEqual(
            SelfUpdatePlanner.action(helperEnabled: true, assetURL: url("https://example.com/Wega.pkg")),
            .install
        )
    }

    func testPkgWithoutHelperOnlyDownloadsAndOpens() {
        XCTAssertEqual(
            SelfUpdatePlanner.action(helperEnabled: false, assetURL: url("https://example.com/Wega.pkg")),
            .downloadAndOpen
        )
    }

    /// A `.dmg` is dragged to Applications by the user — even with the helper it is never a
    /// headless install, so the button must say "download and open", not "install".
    func testDmgAlwaysDownloadsAndOpensEvenWithHelper() {
        XCTAssertEqual(
            SelfUpdatePlanner.action(helperEnabled: true, assetURL: url("https://example.com/Wega.dmg")),
            .downloadAndOpen
        )
    }

    func testExtensionMatchIsCaseInsensitive() {
        XCTAssertEqual(
            SelfUpdatePlanner.action(helperEnabled: true, assetURL: url("https://example.com/Wega.PKG")),
            .install
        )
    }
}
