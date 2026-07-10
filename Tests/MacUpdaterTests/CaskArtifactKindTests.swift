import XCTest
@testable import MacUpdaterCore

/// `CaskArtifactKind` round-trips Homebrew's stanza names. `init(rawKey:)` was exercised by
/// the parser tests; `rawKey` — the way back out — was not, so nothing pinned that an
/// unrecognised stanza survives the trip instead of being silently normalised away.
final class CaskArtifactKindTests: XCTestCase {
    func testEveryKnownStanzaRoundTripsThroughItsRawKey() {
        for kind: CaskArtifactKind in [.app, .binary, .zap, .pkg, .installer, .preflight] {
            XCTAssertEqual(CaskArtifactKind(rawKey: kind.rawKey), kind, "round trip failed for \(kind.rawKey)")
        }
    }

    func testKnownStanzasSpellTheirHomebrewNames() {
        XCTAssertEqual(CaskArtifactKind.app.rawKey, "app")
        XCTAssertEqual(CaskArtifactKind.binary.rawKey, "binary")
        XCTAssertEqual(CaskArtifactKind.zap.rawKey, "zap")
        XCTAssertEqual(CaskArtifactKind.pkg.rawKey, "pkg")
        XCTAssertEqual(CaskArtifactKind.installer.rawKey, "installer")
        XCTAssertEqual(CaskArtifactKind.preflight.rawKey, "preflight")
    }

    /// Homebrew's stanza vocabulary is not enumerated anywhere we control. An unknown one
    /// keeps its name — which is also why `BackgroundUpdateEligibility` refuses it rather
    /// than assuming it is harmless.
    func testAnUnknownStanzaKeepsItsNameVerbatim() {
        XCTAssertEqual(CaskArtifactKind(rawKey: "font"), .other("font"))
        XCTAssertEqual(CaskArtifactKind.other("font").rawKey, "font")
        XCTAssertEqual(CaskArtifactKind(rawKey: CaskArtifactKind.other("suite").rawKey), .other("suite"))
    }
}
