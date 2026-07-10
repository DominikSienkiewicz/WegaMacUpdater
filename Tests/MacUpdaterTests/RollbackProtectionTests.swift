import XCTest
@testable import MacUpdaterCore

/// M5 — Wega snapshots an app before upgrading it, runs a Gatekeeper canary afterwards, and
/// restores the snapshot if the new version fails. That safety net is the product's whole
/// argument, and until now it left no trace in the UI.
///
/// It also has a hole: the snapshot is a clone of an `.app` bundle, so a cask that installs
/// no app — a `pkg`, an `installer` — gets no protection at all, silently. The predicate
/// exists to make the badge honest in both directions: a shield where there is a net, and a
/// stated "no protection" where there is none.
final class RollbackProtectionTests: XCTestCase {
    private func profile(_ kinds: [CaskArtifactKind]) -> CaskArtifactProfile {
        CaskArtifactProfile(token: "t", artifacts: kinds.map { CaskArtifact(kind: $0) })
    }

    func testCaskThatInstallsAnAppIsProtected() {
        XCTAssertEqual(RollbackProtection.evaluate(profile: profile([.app, .zap])), .protected)
    }

    /// A pkg-cask cannot be cloned or restored — say so, do not imply a net that isn't there.
    func testPkgOnlyCaskIsUnprotected() {
        XCTAssertEqual(RollbackProtection.evaluate(profile: profile([.pkg])), .unprotected(.noAppBundle))
    }

    func testInstallerOnlyCaskIsUnprotected() {
        XCTAssertEqual(RollbackProtection.evaluate(profile: profile([.installer])), .unprotected(.noAppBundle))
    }

    /// A CLI-only cask has nothing to roll back either.
    func testBinaryOnlyCaskIsUnprotected() {
        XCTAssertEqual(RollbackProtection.evaluate(profile: profile([.binary])), .unprotected(.noAppBundle))
    }

    /// An app plus a pkg is still snapshot-able — the app bundle is what we clone.
    func testCaskWithBothAnAppAndAPkgIsProtected() {
        XCTAssertEqual(RollbackProtection.evaluate(profile: profile([.app, .pkg])), .protected)
    }

    func testCaskWithNoArtifactsIsUnprotected() {
        XCTAssertEqual(RollbackProtection.evaluate(profile: profile([])), .unprotected(.noAppBundle))
    }

    /// The silent hole this predicate exists to expose: an unprotected cask must be
    /// loud enough to log, not merely absent from the happy path.
    func testUnprotectedCasksAreWorthLogging() {
        XCTAssertTrue(RollbackProtection.evaluate(profile: profile([.pkg])).deservesWarning)
        XCTAssertFalse(RollbackProtection.evaluate(profile: profile([.app])).deservesWarning)
    }
}
