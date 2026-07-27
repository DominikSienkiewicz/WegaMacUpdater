import CryptoKit
import Foundation
import Testing
@testable import MacUpdaterCore

private final class EnvelopeFakeTransport: HTTPTransport, @unchecked Sendable {
    struct Stub { let data: Data; let status: Int; let headers: [String: String] }
    private let lock = NSLock()
    private var queue: [Stub]
    /// Every URL the client actually asked for, in order — how the suite proves the
    /// envelope costs *one* request where the detached layout costs two.
    private(set) var requestedURLs: [URL] = []

    init(_ responses: [Stub]) { queue = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let stub: Stub = lock.withLock {
            requestedURLs.append(request.url!)
            return queue.isEmpty ? Stub(data: Data(), status: 404, headers: [:]) : queue.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers
        )!
        return (stub.data, response)
    }
}

/// SEC-07 — replay/downgrade protection, hard `schemaVersion`, and the one-document
/// envelope that removes the two-file CDN skew.
///
/// The three failures this covers share a shape: each one lets something *look* fine.
///
/// - An old catalog carries an old signature that is genuinely valid, so replaying it
///   forges nothing — the only thing that can distinguish "old" from "current" is a
///   counter inside the signed bytes.
/// - A future catalog decoded cleanly as an **empty** catalog, because every section is
///   `decodeIfPresent`. An empty catalog is indistinguishable from "nothing configured", so
///   a format bump would have switched every catalog-driven checker off without a word.
/// - A fresh `app-catalog.json` beside a cached `app-catalog.json.sig` produced a signature
///   mismatch that is cryptographically identical to tampering. One document cannot skew
///   against itself.
@Suite("SEC-07 — catalog replay, schema and envelope")
struct SEC07CatalogEnvelopeTests {

    private let source = URL(string: "https://example.com/app-catalog.json")!
    private let signingKey = Curve25519.Signing.PrivateKey()

    private var verifier: CatalogSignature {
        CatalogSignature(publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString())
    }

    private func catalogJSON(schemaVersion: Int = 1, generation: Int, token: String = "x") -> String {
        """
        {"schemaVersion":\(schemaVersion),"generation":\(generation),\
        "github":[{"bundleId":"com.x.app","repo":"owner/repo","caskToken":"\(token)"}]}
        """
    }

    private func envelope(wrapping payload: String, version: Int = 1) throws -> String {
        let bytes = Data(payload.utf8)
        let signature = try signingKey.signature(for: bytes).base64EncodedString()
        return """
        {"wegaCatalogEnvelope":\(version),"payload":"\(bytes.base64EncodedString())","signature":"\(signature)"}
        """
    }

    private func tempDestination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-sec07-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("app-catalog.json")
    }

    private func ledger() -> (CatalogGenerationLedger, UserDefaults) {
        let suite = "wega.sec07.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (CatalogGenerationLedger(defaults: defaults), defaults)
    }

    // MARK: The envelope

    @Test("An envelope is verified against its payload and costs a single request")
    func envelopeIsVerifiedAndFetchedOnce() async throws {
        let dest = tempDestination()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let payload = catalogJSON(generation: 4)
        let transport = EnvelopeFakeTransport([
            .init(data: Data(try envelope(wrapping: payload).utf8), status: 200, headers: [:])
        ])
        let (generations, defaults) = ledger()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let outcome = await CatalogRefresher(
            source: source, destination: dest,
            client: HTTPClient(transport: transport, maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier, generations: generations
        ).refresh()

        #expect(outcome == .updated)
        #expect(transport.requestedURLs.count == 1,
                "the envelope carries its own signature — there is no sibling .sig to fetch")
        #expect(transport.requestedURLs.allSatisfy { !$0.absoluteString.hasSuffix(".sig") })
        // The *payload* lands on disk, not the wrapper — `loadOverlay` reads a flat catalog.
        #expect(try Data(contentsOf: dest) == Data(payload.utf8))
        #expect(try AppCatalog.decode(contentsOf: dest).github.first?.caskToken == "x")
    }

    /// The point of the wrapper: the signature covers the payload, so rewriting the payload
    /// while keeping the signature has to fail. This is what makes one document safe.
    @Test("An envelope whose payload was swapped under its signature is refused")
    func swappedPayloadUnderASignatureIsRefused() async throws {
        let dest = tempDestination()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let honest = try envelope(wrapping: catalogJSON(generation: 4))
        let hostile = honest.replacingOccurrences(
            of: Data(catalogJSON(generation: 4).utf8).base64EncodedString(),
            with: Data(catalogJSON(generation: 4, token: "hostile").utf8).base64EncodedString()
        )
        let (generations, defaults) = ledger()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let outcome = await CatalogRefresher(
            source: source, destination: dest,
            client: HTTPClient(transport: EnvelopeFakeTransport([
                .init(data: Data(hostile.utf8), status: 200, headers: [:])
            ]), maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier, generations: generations
        ).refresh()

        #expect(outcome == .signatureMismatch)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    /// An envelope handed to the bare catalog decoder decodes as a perfectly valid *empty*
    /// catalog — every section is optional. Trying the envelope first is what stops that.
    @Test("An envelope is never mistaken for an empty catalog")
    func envelopeIsNotMistakenForAnEmptyCatalog() throws {
        let wrapped = Data(try envelope(wrapping: catalogJSON(generation: 2)).utf8)

        let bare = try? JSONDecoder().decode(AppCatalog.self, from: wrapped)
        #expect(bare?.github.isEmpty == true,
                "precondition: the bare decoder really does accept an envelope as empty")

        #expect(try AppCatalog.decode(wrapped).github.count == 1)
    }

    /// A wrapper version from the future is the same story as a schema from the future, and
    /// gets the same answer — including the same "update Wega" wording, rather than a
    /// generic "invalid" that reads like a broken download.
    @Test("An envelope in an unknown wrapper version is refused, not guessed at")
    func unknownEnvelopeVersionIsRefused() async throws {
        let dest = tempDestination()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let future = try envelope(wrapping: catalogJSON(generation: 4), version: 99)
        let (generations, defaults) = ledger()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let outcome = await CatalogRefresher(
            source: source, destination: dest,
            client: HTTPClient(transport: EnvelopeFakeTransport([
                .init(data: Data(future.utf8), status: 200, headers: [:])
            ]), maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier, generations: generations
        ).refresh()

        #expect(outcome == .unsupportedSchema)
    }

    // MARK: Replay / downgrade

    @Test("A catalog older than the one already accepted is refused")
    func olderGenerationIsRefused() async throws {
        let dest = tempDestination()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let (generations, defaults) = ledger()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        generations.record(7)

        let outcome = await CatalogRefresher(
            source: source, destination: dest,
            client: HTTPClient(transport: EnvelopeFakeTransport([
                .init(data: Data(try envelope(wrapping: catalogJSON(generation: 3)).utf8),
                      status: 200, headers: [:])
            ]), maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier, generations: generations
        ).refresh()

        #expect(outcome == .replayRejected)
        #expect(!FileManager.default.fileExists(atPath: dest.path),
                "a replayed catalog must not touch the overlay")
    }

    /// The whole attack is "wait for a relaunch", so the watermark has to outlive the
    /// process that learned it.
    @Test("The accepted generation survives a relaunch")
    func acceptedGenerationIsPersisted() async throws {
        let dest = tempDestination()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let suite = "wega.sec07.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstRun = await CatalogRefresher(
            source: source, destination: dest,
            client: HTTPClient(transport: EnvelopeFakeTransport([
                .init(data: Data(try envelope(wrapping: catalogJSON(generation: 9)).utf8),
                      status: 200, headers: [:])
            ]), maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier,
            generations: CatalogGenerationLedger(defaults: defaults)
        ).refresh()
        #expect(firstRun == .updated)

        // A fresh ledger over the same defaults is exactly what the next launch builds.
        #expect(CatalogGenerationLedger(defaults: defaults).accepted == 9)
        let afterRelaunch = await CatalogRefresher(
            source: source, destination: dest,
            client: HTTPClient(transport: EnvelopeFakeTransport([
                .init(data: Data(try envelope(wrapping: catalogJSON(generation: 8)).utf8),
                      status: 200, headers: [:])
            ]), maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier,
            generations: CatalogGenerationLedger(defaults: defaults)
        ).refresh()

        #expect(afterRelaunch == .replayRejected)
    }

    @Test("Re-serving the same generation is ordinary caching, not an attack")
    func equalGenerationIsAccepted() {
        #expect(CatalogGenerationPolicy.accepts(candidate: 5, accepted: 5))
        #expect(CatalogGenerationPolicy.accepts(candidate: 6, accepted: 5))
        #expect(!CatalogGenerationPolicy.accepts(candidate: 4, accepted: 5))
    }

    /// Catalogs published before the field existed carry no generation. They must keep
    /// loading, and the guard must start biting from the first one that has one.
    @Test("A catalog without a generation is treated as zero and still loads")
    func missingGenerationDefaultsToZero() throws {
        let catalog = try AppCatalog.decode(Data(#"{"github":[]}"#.utf8))
        #expect(catalog.generation == 0)
        #expect(catalog.schemaVersion == AppCatalog.supportedSchemaVersion)
    }

    /// The watermark is raised only by a catalog that actually landed: raising it for a
    /// write that failed would refuse the retry that would have fixed it.
    @Test("A failed write leaves the watermark where it was")
    func failedWriteDoesNotRaiseTheWatermark() async throws {
        let (generations, defaults) = ledger()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        // A destination whose parent cannot be created — the write must fail.
        let unwritable = URL(fileURLWithPath: "/dev/null/nope/app-catalog.json")

        let outcome = await CatalogRefresher(
            source: source, destination: unwritable,
            client: HTTPClient(transport: EnvelopeFakeTransport([
                .init(data: Data(try envelope(wrapping: catalogJSON(generation: 11)).utf8),
                      status: 200, headers: [:])
            ]), maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier, generations: generations
        ).refresh()

        #expect(outcome == .failed)
        #expect(generations.accepted == 0)
    }

    // MARK: Hard schemaVersion

    @Test("A catalog in an unimplemented schema is refused, not decoded as empty")
    func unsupportedSchemaIsRefused() async throws {
        let dest = tempDestination()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let (generations, defaults) = ledger()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let outcome = await CatalogRefresher(
            source: source, destination: dest,
            client: HTTPClient(transport: EnvelopeFakeTransport([
                .init(data: Data(try envelope(wrapping: catalogJSON(schemaVersion: 2, generation: 4)).utf8),
                      status: 200, headers: [:])
            ]), maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier, generations: generations
        ).refresh()

        #expect(outcome == .unsupportedSchema)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("Decoding an unimplemented schema throws instead of yielding an empty catalog")
    func unsupportedSchemaDoesNotDecodeAsEmpty() {
        #expect(throws: (any Error).self) {
            try AppCatalog.decode(Data(#"{"schemaVersion":2,"github":[]}"#.utf8))
        }
    }

    @Test("The bundled catalog is in the schema this build implements")
    func bundledCatalogMatchesTheSupportedSchema() throws {
        #expect(try AppCatalog.loadBundled().schemaVersion == AppCatalog.supportedSchemaVersion)
    }

    // MARK: The legacy detached layout keeps working during the migration

    @Test("A flat catalog beside its detached signature is still accepted")
    func legacyDetachedLayoutStillWorks() async throws {
        let dest = tempDestination()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let payload = catalogJSON(generation: 2)
        let signature = try signingKey.signature(for: Data(payload.utf8)).base64EncodedString()
        let transport = EnvelopeFakeTransport([
            .init(data: Data(payload.utf8), status: 200, headers: [:]),
            .init(data: Data(signature.utf8), status: 200, headers: [:])
        ])
        let (generations, defaults) = ledger()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let outcome = await CatalogRefresher(
            source: source, destination: dest,
            client: HTTPClient(transport: transport, maxRetries: 0, retryBaseDelay: 0),
            signatureVerifier: verifier, generations: generations
        ).refresh()

        #expect(outcome == .updated)
        #expect(transport.requestedURLs.contains { $0.absoluteString.hasSuffix(".sig") },
                "the legacy layout is exactly the two-request shape the envelope replaces")
        #expect(generations.accepted == 2)
    }

    // MARK: The ETag validator survives a relaunch

    /// The catalog is fetched once per launch, so a validator that dies with the process is
    /// never present when it would help — every start re-downloaded the whole catalog.
    @Test("A persisted ETag is offered by a client built after a relaunch")
    func persistedETagSurvivesANewClient() async throws {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-etag-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("etag-cache.json")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let body = Data(catalogJSON(generation: 1).utf8)

        let first = EnvelopeFakeTransport([.init(data: body, status: 200, headers: ["ETag": "\"v1\""])])
        _ = try await HTTPClient(transport: first, maxRetries: 0, retryBaseDelay: 0, etagCacheURL: cache)
            .get(source, enableETag: true)

        // A brand-new client over the same cache file is what the next launch constructs.
        let second = EnvelopeFakeTransport([.init(data: Data(), status: 304, headers: [:])])
        let response = try await HTTPClient(transport: second, maxRetries: 0, retryBaseDelay: 0, etagCacheURL: cache)
            .get(source, enableETag: true)

        #expect(response.notModified, "the second launch revalidated instead of re-downloading")
        #expect(response.data == body, "the 304 is served from the persisted body")
    }

    @Test("Without a cache file the store stays in memory, as every other caller expects")
    func withoutACacheFileTheStoreStaysInMemory() async throws {
        let first = EnvelopeFakeTransport([.init(data: Data("x".utf8), status: 200, headers: ["ETag": "\"v1\""])])
        _ = try await HTTPClient(transport: first, maxRetries: 0, retryBaseDelay: 0)
            .get(source, enableETag: true)

        let second = EnvelopeFakeTransport([.init(data: Data("y".utf8), status: 200, headers: [:])])
        _ = try await HTTPClient(transport: second, maxRetries: 0, retryBaseDelay: 0).get(source, enableETag: true)

        #expect(!second.requestedURLs.isEmpty)
    }
}
