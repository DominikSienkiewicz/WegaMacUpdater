import XCTest
@testable import MacUpdaterCore

/// F2 — the plan preview says "may require an admin password", never "will".
///
/// `brew info --json` reveals that a cask *has* a `pkg` / `installer` / `preflight` stanza,
/// but not what that stanza does. Presence is detectable, content is not. So the label is a
/// possibility, and the code refuses to promise otherwise.
final class AdminPasswordLikelihoodTests: XCTestCase {
    private func profile(_ kinds: [CaskArtifactKind]) -> CaskArtifactProfile {
        CaskArtifactProfile(token: "t", artifacts: kinds.map { CaskArtifact(kind: $0) })
    }

    func testPlainAppCaskWillNotAskForAPassword() {
        XCTAssertFalse(profile([.app, .zap]).mayRequireAdminPassword)
    }

    func testPkgCaskMayAskForAPassword() {
        XCTAssertTrue(profile([.pkg]).mayRequireAdminPassword)
    }

    func testInstallerCaskMayAskForAPassword() {
        XCTAssertTrue(profile([.app, .installer]).mayRequireAdminPassword)
    }

    /// A preflight hook runs arbitrary code before install; it can absolutely prompt.
    func testPreflightHookMayAskForAPassword() {
        XCTAssertTrue(profile([.app, .preflight]).mayRequireAdminPassword)
    }

    func testBinaryOnlyCaskWillNotAskForAPassword() {
        XCTAssertFalse(profile([.binary]).mayRequireAdminPassword)
    }

    /// An unrecognised stanza is not evidence of a prompt — we only flag what we can see.
    func testUnknownStanzaAloneDoesNotFlagAPasswordPrompt() {
        XCTAssertFalse(profile([.other("font")]).mayRequireAdminPassword)
    }
}
