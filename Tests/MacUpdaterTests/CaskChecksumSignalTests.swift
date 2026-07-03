import XCTest
@testable import MacUpdaterCore

/// The Trust panel's checksum signal must apply ONLY to a plain `.cask` source — that's
/// the only case backed by `caskDownloads`. Other cask-adjacent sources (jetbrains,
/// self-updating apps) are surfaced by different checkers and have no checksum entry,
/// so this must return nil for them rather than let the panel show a false "absent" (I-4).
final class CaskChecksumSignalTests: XCTestCase {

    func testCaskSourceReturnsItsToken() {
        XCTAssertEqual(caskChecksumToken(of: .cask(token: "figma")), "figma")
    }

    func testSparkleSourceReturnsNil() {
        XCTAssertNil(caskChecksumToken(of: .sparkle))
    }

    func testJetbrainsSourceReturnsNil() {
        XCTAssertNil(caskChecksumToken(of: .jetbrains(caskToken: "intellij-idea")))
    }

    func testGithubSourceReturnsNil() {
        XCTAssertNil(caskChecksumToken(of: .github(repo: "owner/repo")))
    }
}
