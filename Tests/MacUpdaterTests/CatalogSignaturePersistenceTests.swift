import XCTest
import CryptoKit
@testable import MacUpdaterCore

/// F5(a) — `CatalogRefresher` verified the detached signature and then threw it away, writing
/// only the JSON. Now that `AppCatalog.loadOverlay` verifies on read too, an overlay written
/// without its signature could never be loaded again: silently degraded to the bundled
/// catalog, forever, while every refresh reported success.
///
/// The verifier is injected, which is the whole point of the F5(a) refactor — with the key as
/// a `static let` there was no way to reach the configured branch from a test.
final class CatalogSignaturePersistenceTests: XCTestCase {
    private var directory: URL!
    private var destination: URL!
    private var signingKey: Curve25519.Signing.PrivateKey!
    private var verifier: CatalogSignature!

    private let catalogJSON = "{\"synology\":[],\"sparkleFeedOverrides\":[]}"

    private var signatureURL: URL { AppCatalog.signatureURL(for: destination) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-refresh-\(UUID().uuidString)", isDirectory: true)
        destination = directory.appendingPathComponent("app-catalog.json")
        signingKey = Curve25519.Signing.PrivateKey()
        verifier = CatalogSignature(publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func validSignature(over body: String) throws -> String {
        try signingKey.signature(for: Data(body.utf8)).base64EncodedString()
    }

    private func refresher(
        body: String? = nil,
        signature: String?,
        verifier: CatalogSignature? = nil
    ) -> CatalogRefresher {
        var responses: [Result<FakeHTTPTransport.Stub, Error>] = [
            .success(.init(data: Data((body ?? catalogJSON).utf8), status: 200, headers: [:]))
        ]
        responses.append(signature.map { .success(.init(data: Data($0.utf8), status: 200, headers: [:])) }
                         ?? .success(.init(data: Data(), status: 404, headers: [:])))
        return CatalogRefresher(
            source: URL(string: "https://example.test/app-catalog.json")!,
            destination: destination,
            client: HTTPClient(transport: FakeHTTPTransport(responses)),
            signatureVerifier: verifier ?? self.verifier
        )
    }

    // MARK: Signing configured — fail-closed

    /// The regression this suite exists for: the verified signature lands beside the catalog.
    func testAVerifiedSignatureIsPersistedBesideTheCatalog() async throws {
        let signature = try validSignature(over: catalogJSON)

        let outcome = await refresher(signature: signature).refresh()

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), catalogJSON)
        XCTAssertEqual(
            try String(contentsOf: signatureURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            signature
        )
    }

    func testAMissingSignatureIsRejectedAndNothingIsWritten() async throws {
        let outcome = await refresher(signature: nil).refresh()

        XCTAssertEqual(outcome, .invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// A signature over different bytes — a tampered catalog, or a stale `.sig` on the CDN.
    func testASignatureOverDifferentBytesIsRejected() async throws {
        let signature = try validSignature(over: "{\"synology\":[]}")

        let outcome = await refresher(signature: signature).refresh()

        XCTAssertEqual(outcome, .invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testASignatureFromAnotherKeyIsRejected() async throws {
        let attacker = Curve25519.Signing.PrivateKey()
        let forged = try attacker.signature(for: Data(catalogJSON.utf8)).base64EncodedString()

        let outcome = await refresher(signature: forged).refresh()

        XCTAssertEqual(outcome, .invalid)
    }

    /// Validation precedes signing: a 200 with a garbage body must not replace a good overlay.
    func testAGarbageBodyIsRejectedBeforeTheSignatureIsEvenFetched() async throws {
        let outcome = await refresher(body: "not json", signature: nil).refresh()

        XCTAssertEqual(outcome, .invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Signing not configured — decode-only, as before

    private var unconfigured: CatalogSignature {
        CatalogSignature(publicKeyBase64: CatalogSignature.unconfiguredPlaceholder)
    }

    func testAnUnsignedBuildStillWritesTheCatalog() async throws {
        let outcome = await refresher(signature: nil, verifier: unconfigured).refresh()

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), catalogJSON)
    }

    /// A `.sig` left behind by a previously-signed build vouches for bytes that no longer
    /// exist. Left in place, `loadOverlay` would reject the fresh catalog and strand the user
    /// on the bundled one — a failure with no symptom.
    func testAStaleSignatureIsRemovedWhenWritingAnUnsignedCatalog() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "stale-signature".write(to: signatureURL, atomically: true, encoding: .utf8)

        let outcome = await refresher(signature: nil, verifier: unconfigured).refresh()

        XCTAssertEqual(outcome, .updated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: signatureURL.path))
    }
}
