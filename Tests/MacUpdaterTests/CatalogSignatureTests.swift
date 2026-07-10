import XCTest
import CryptoKit
@testable import MacUpdaterCore

/// F5(a) — the fail-closed path, which until now could not be tested at all because the
/// publisher key was a `static let` compiled into the type.
///
/// The bug this suite exists to catch: `isConfigured` compared `publicKeyBase64` against a
/// *repeated string literal* of the placeholder. Pasting a real key over both occurrences —
/// the obvious thing to do with a find-and-replace — turned the check into `key != key`,
/// permanently false, silently disabling every signature check in the app while the
/// signature itself verified perfectly by hand.
final class CatalogSignatureTests: XCTestCase {
    private let unconfigured = CatalogSignature(publicKeyBase64: CatalogSignature.unconfiguredPlaceholder)

    /// A key pair, the bytes it signed, and the detached signature over them.
    private struct SignedFixture {
        let verifier: CatalogSignature
        let data: Data
        let signature: String
    }

    private func signed() throws -> SignedFixture {
        let privateKey = Curve25519.Signing.PrivateKey()
        let data = Data("{\"apps\":[]}".utf8)
        return SignedFixture(
            verifier: CatalogSignature(publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()),
            data: data,
            signature: try privateKey.signature(for: data).base64EncodedString()
        )
    }

    // MARK: Configured

    /// The regression: a real key means configured, whatever that key happens to be.
    func testARealKeyMeansConfigured() throws {
        XCTAssertTrue(try signed().verifier.isConfigured)
    }

    func testAValidSignatureIsAccepted() throws {
        let f = try signed()
        XCTAssertTrue(f.verifier.verify(data: f.data, signatureBase64: f.signature))
    }

    func testASignatureOverDifferentBytesIsRejected() throws {
        let f = try signed()
        XCTAssertFalse(f.verifier.verify(data: f.data + Data(" ".utf8), signatureBase64: f.signature))
    }

    func testASignatureFromAnotherKeyIsRejected() throws {
        let f = try signed()
        let attacker = Curve25519.Signing.PrivateKey()
        let forged = try attacker.signature(for: f.data).base64EncodedString()
        XCTAssertFalse(f.verifier.verify(data: f.data, signatureBase64: forged))
    }

    func testGarbageSignatureIsRejected() throws {
        let f = try signed()
        XCTAssertFalse(f.verifier.verify(data: f.data, signatureBase64: "not base64 at all !!!"))
    }

    func testAnEmptySignatureIsRejected() throws {
        let f = try signed()
        XCTAssertFalse(f.verifier.verify(data: f.data, signatureBase64: ""))
    }

    /// Signatures travel in files that end with a newline. Trimming is part of the contract.
    func testSurroundingWhitespaceInTheSignatureIsTolerated() throws {
        let f = try signed()
        XCTAssertTrue(f.verifier.verify(data: f.data, signatureBase64: "\n  \(f.signature)  \n"))
    }

    // MARK: Unconfigured

    func testThePlaceholderMeansUnconfigured() {
        XCTAssertFalse(unconfigured.isConfigured)
    }

    /// Unconfigured never verifies anything — callers must gate on `isConfigured` and fall
    /// back to decode-only validation rather than treating `false` as "bad signature".
    func testAnUnconfiguredVerifierRejectsEvenAValidSignature() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let data = Data("x".utf8)
        let signature = try privateKey.signature(for: data).base64EncodedString()
        XCTAssertFalse(unconfigured.verify(data: data, signatureBase64: signature))
    }

    func testAMalformedKeyMeansUnconfigured() {
        XCTAssertFalse(CatalogSignature(publicKeyBase64: "!!! not base64 !!!").isConfigured)
    }

    /// 31 bytes is not an Ed25519 key. Refuse rather than crash inside CryptoKit.
    func testAKeyOfTheWrongLengthMeansUnconfigured() {
        let short = Data(repeating: 0, count: 31).base64EncodedString()
        XCTAssertFalse(CatalogSignature(publicKeyBase64: short).isConfigured)
    }

    // MARK: The shipped key

    /// The key actually compiled into this build. Once one is pasted in, signing is on —
    /// and if it is ever reverted to the placeholder, this says so out loud instead of
    /// letting the app quietly stop checking signatures.
    func testTheShippedBuildReportsItsSigningStateHonestly() {
        XCTAssertEqual(
            CatalogSignature.shared.isConfigured,
            CatalogSignature.publicKeyBase64 != CatalogSignature.unconfiguredPlaceholder
        )
    }
}
