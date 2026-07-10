import XCTest
@testable import MacUpdaterCore

/// F5(a) — the two overlay files are trusted differently, on purpose.
///
/// **`app-catalog.json`** arrives over the network from a repository anyone may open a pull
/// request against. It is fail-closed: no valid signature, no overlay.
///
/// **`endpoints.json`** is a file the user places on their own disk to redirect a feed a
/// vendor has moved, without waiting for a release. A signature would protect nothing there
/// — anyone who can write to Application Support can do worse — so it stays usable unsigned,
/// and every unsigned use is logged. What it must *not* do is accept a signature that is
/// present and wrong: that means tampering, not convenience.
final class ConfigOverlayTrustTests: XCTestCase {
    // MARK: Catalog — fail-closed

    func testCatalogWithAValidSignatureIsAccepted() {
        XCTAssertEqual(
            ConfigOverlayTrust.forCatalog(signingConfigured: true, signature: "sig", isValid: true),
            .accept
        )
    }

    func testCatalogWithoutASignatureIsRejected() {
        XCTAssertEqual(
            ConfigOverlayTrust.forCatalog(signingConfigured: true, signature: nil, isValid: false),
            .reject
        )
    }

    func testCatalogWithAnInvalidSignatureIsRejected() {
        XCTAssertEqual(
            ConfigOverlayTrust.forCatalog(signingConfigured: true, signature: "sig", isValid: false),
            .reject
        )
    }

    /// Before a publisher key ships, an unsigned dev setup must not brick.
    func testCatalogIsAcceptedWhenSigningIsNotConfiguredAtAll() {
        XCTAssertEqual(
            ConfigOverlayTrust.forCatalog(signingConfigured: false, signature: nil, isValid: false),
            .accept
        )
    }

    // MARK: Endpoints — usable unsigned, but never mis-signed

    func testEndpointsWithoutASignatureIsAcceptedAndWorthWarningAbout() {
        let decision = ConfigOverlayTrust.forEndpoints(signingConfigured: true, signature: nil, isValid: false)
        XCTAssertEqual(decision, .acceptUnsigned)
        XCTAssertTrue(decision.deservesWarning)
    }

    func testEndpointsWithAValidSignatureIsAcceptedQuietly() {
        let decision = ConfigOverlayTrust.forEndpoints(signingConfigured: true, signature: "sig", isValid: true)
        XCTAssertEqual(decision, .accept)
        XCTAssertFalse(decision.deservesWarning)
    }

    /// A signature that is present and wrong is the one case that is not convenience.
    func testEndpointsWithAnInvalidSignatureIsRejected() {
        XCTAssertEqual(
            ConfigOverlayTrust.forEndpoints(signingConfigured: true, signature: "sig", isValid: false),
            .reject
        )
    }

    func testEndpointsIsAcceptedQuietlyWhenSigningIsNotConfigured() {
        let decision = ConfigOverlayTrust.forEndpoints(signingConfigured: false, signature: nil, isValid: false)
        XCTAssertEqual(decision, .accept)
        XCTAssertFalse(decision.deservesWarning)
    }

    /// Only an accepted overlay may be applied — `acceptUnsigned` included.
    func testOnlyRejectionStopsTheOverlayFromBeingApplied() {
        XCTAssertTrue(ConfigOverlayTrust.Decision.accept.appliesOverlay)
        XCTAssertTrue(ConfigOverlayTrust.Decision.acceptUnsigned.appliesOverlay)
        XCTAssertFalse(ConfigOverlayTrust.Decision.reject.appliesOverlay)
    }
}
