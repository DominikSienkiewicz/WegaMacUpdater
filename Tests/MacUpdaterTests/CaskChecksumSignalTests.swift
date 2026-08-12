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
        XCTAssertNil(caskChecksumToken(of: .github(repo: "owner/repo", selfUpdates: false)))
    }

    // MARK: - Three-state signal (UX-05)

    /// A plain cask with a real sha256 → the checksum is present.
    func testCaskWithRealChecksumIsPresent() {
        let downloads = ["figma": CaskDownloadInfo(token: "figma", url: nil, sha256: "abc123")]
        XCTAssertEqual(caskChecksumSignal(token: "figma", downloads: downloads), .present)
    }

    /// A `no_check` cask installs without verification → a genuinely *absent* checksum, which
    /// stays a negative signal (it is a real answer, not missing data).
    func testCaskWithNoCheckIsAbsent() {
        let downloads = ["figma": CaskDownloadInfo(token: "figma", url: nil, sha256: "no_check")]
        XCTAssertEqual(caskChecksumSignal(token: "figma", downloads: downloads), .absent)
    }

    /// UX-05, the whole point: a cask whose download info has not been fetched (e.g. right
    /// after a relaunch, before the first scan re-populates `caskDownloads`) is *unknown* —
    /// NOT absent. Missing data must never render as a negative "no checksum" verdict.
    func testCaskWithoutDownloadEntryIsUnknownNotAbsent() {
        XCTAssertEqual(caskChecksumSignal(token: "figma", downloads: [:]), .unknown)
        XCTAssertNotEqual(caskChecksumSignal(token: "figma", downloads: [:]), .absent)
    }

    /// A non-cask (nil token) has no checksum question to answer at all.
    func testNilTokenIsNotApplicable() {
        XCTAssertEqual(caskChecksumSignal(token: nil, downloads: [:]), .notApplicable)
    }

    /// The source-based overload agrees with the token overload for a `.cask` source with no
    /// download info yet.
    func testCaskSourceWithoutDownloadsIsUnknown() {
        XCTAssertEqual(caskChecksumSignal(of: .cask(token: "figma"), downloads: [:]), .unknown)
    }

    /// A source that is not a plain cask is not applicable, whatever the downloads hold.
    func testSparkleSourceIsNotApplicable() {
        let downloads = ["figma": CaskDownloadInfo(token: "figma", url: nil, sha256: "abc123")]
        XCTAssertEqual(caskChecksumSignal(of: .sparkle, downloads: downloads), .notApplicable)
    }

    // MARK: - Bridge into `trustLevel`

    /// `unknown` and `notApplicable` contribute nothing to the verdict; only a real answer does.
    func testChecksumPresenceBridge() {
        XCTAssertEqual(CaskChecksumSignal.present.checksumPresence, true)
        XCTAssertEqual(CaskChecksumSignal.absent.checksumPresence, false)
        XCTAssertNil(CaskChecksumSignal.unknown.checksumPresence)
        XCTAssertNil(CaskChecksumSignal.notApplicable.checksumPresence)
    }

    /// An unknown checksum, alone, is `.unavailable` — never a warning.
    func testUnknownChecksumIsNotAWarning() {
        let verdict = trustLevel(
            audit: nil, signatureValid: nil,
            caskChecksumPresent: CaskChecksumSignal.unknown.checksumPresence)
        XCTAssertEqual(verdict, .unavailable)
    }

    /// A genuinely absent checksum stays a warning.
    func testAbsentChecksumIsAWarning() {
        let verdict = trustLevel(
            audit: nil, signatureValid: nil,
            caskChecksumPresent: CaskChecksumSignal.absent.checksumPresence)
        XCTAssertEqual(verdict, .warning)
    }
}
