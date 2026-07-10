import XCTest
@testable import MacUpdaterCore

/// F3 — which casks Wega may ever upgrade **unattended**.
///
/// The bar is deliberately high: a background upgrade is only defensible when it can be
/// verified and undone. That means no privileged hooks (`pkg` / `installer` / `preflight`
/// can ask for an admin password or run arbitrary code), and a concrete `sha256` so
/// Homebrew actually verifies what it downloaded. Everything else stays a one-click,
/// user-present upgrade — the honest framing is "safe = automatic, the rest = one click",
/// never "everything updates itself".
final class BackgroundUpdateEligibilityTests: XCTestCase {
    private func profile(_ token: String, _ kinds: [CaskArtifactKind]) -> CaskArtifactProfile {
        CaskArtifactProfile(token: token, artifacts: kinds.map { CaskArtifact(kind: $0) })
    }

    private func download(_ token: String, sha256: String?) -> CaskDownloadInfo {
        CaskDownloadInfo(token: token, url: "https://example.test/\(token).dmg", sha256: sha256)
    }

    func testPlainAppCaskWithChecksumIsEligible() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("iterm2", [.app, .zap]),
            download: download("iterm2", sha256: String(repeating: "a", count: 64))
        )
        XCTAssertEqual(verdict, .eligible)
    }

    func testBinaryAndAppAndZapTogetherAreStillEligible() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("alacritty", [.app, .binary, .zap]),
            download: download("alacritty", sha256: String(repeating: "b", count: 64))
        )
        XCTAssertEqual(verdict, .eligible)
    }

    /// Parallels ships a `preflight` hook — arbitrary code before install, possibly a
    /// password prompt. Never in the background.
    func testCaskWithPreflightHookIsRejected() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("parallels", [.app, .preflight]),
            download: download("parallels", sha256: String(repeating: "c", count: 64))
        )
        XCTAssertEqual(verdict, .ineligible(.privilegedArtifact))
    }

    func testCaskWithPkgArtifactIsRejected() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("some-pkg-cask", [.pkg]),
            download: download("some-pkg-cask", sha256: String(repeating: "d", count: 64))
        )
        XCTAssertEqual(verdict, .ineligible(.privilegedArtifact))
    }

    func testCaskWithInstallerArtifactIsRejected() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("some-installer-cask", [.app, .installer]),
            download: download("some-installer-cask", sha256: String(repeating: "e", count: 64))
        )
        XCTAssertEqual(verdict, .ineligible(.privilegedArtifact))
    }

    /// google-chrome is `app` + `zap` — but its download is `:no_check`, so brew verifies
    /// nothing. Unattended install of an unverified binary is exactly what we refuse.
    func testCaskWithoutChecksumIsRejected() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("google-chrome", [.app, .zap]),
            download: download("google-chrome", sha256: "no_check")
        )
        XCTAssertEqual(verdict, .ineligible(.noChecksum))
    }

    func testCaskWithMissingDownloadInfoIsRejected() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("mystery", [.app]),
            download: nil
        )
        XCTAssertEqual(verdict, .ineligible(.noChecksum))
    }

    /// An unrecognised stanza is not proof of safety — refuse rather than guess.
    func testCaskWithUnknownArtifactKindIsRejected() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("font-hack", [.other("font")]),
            download: download("font-hack", sha256: String(repeating: "f", count: 64))
        )
        XCTAssertEqual(verdict, .ineligible(.privilegedArtifact))
    }

    /// A cask that declares no artifacts at all tells us nothing. Not eligible.
    func testCaskWithNoArtifactsIsRejected() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("empty", []),
            download: download("empty", sha256: String(repeating: "0", count: 64))
        )
        XCTAssertEqual(verdict, .ineligible(.noArtifacts))
    }

    /// The privileged-artifact check outranks the checksum check: a `pkg` cask without a
    /// checksum is refused for the more fundamental reason.
    func testPrivilegedArtifactOutranksMissingChecksum() {
        let verdict = BackgroundUpdateEligibility.evaluate(
            profile: profile("bad", [.pkg]),
            download: download("bad", sha256: nil)
        )
        XCTAssertEqual(verdict, .ineligible(.privilegedArtifact))
    }
}
