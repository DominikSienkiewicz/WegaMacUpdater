import Foundation

/// The signed OTA catalog, carried as **one** document (SEC-07).
///
/// The detached layout — `app-catalog.json` beside `app-catalog.json.sig` — has a flaw that
/// no amount of care at signing time removes: `raw.githubusercontent` serves the two as
/// separate cache entries, so a client can fetch a fresh catalog next to a stale signature
/// and see a mismatch that is cryptographically indistinguishable from an attack
/// (``CatalogRefresher/Outcome/signatureMismatch``). One document cannot skew against
/// itself.
///
/// The envelope is deliberately dumb: its own fields are *untrusted*. Everything a decision
/// rests on — the schema version and the monotonic generation that makes a replay
/// detectable — lives inside `payload`, the exact bytes the signature covers. An attacker
/// who rewrites the envelope's outer fields changes nothing; an attacker who rewrites the
/// payload invalidates the signature.
///
/// `payload` is base64 rather than nested JSON on purpose: the signature is over exact
/// bytes, and nesting would make verification depend on re-serializing someone else's JSON
/// byte-for-byte.
public struct CatalogEnvelope: Decodable, Sendable, Equatable {
    /// Envelope format version — the wrapper's own shape, not the catalog's schema.
    public static let currentVersion = 1

    public let version: Int
    public let payloadBase64: String
    public let signatureBase64: String

    public init(version: Int = CatalogEnvelope.currentVersion, payloadBase64: String, signatureBase64: String) {
        self.version = version
        self.payloadBase64 = payloadBase64
        self.signatureBase64 = signatureBase64
    }

    private enum CodingKeys: String, CodingKey {
        case version = "wegaCatalogEnvelope"
        case payloadBase64 = "payload"
        case signatureBase64 = "signature"
    }

    /// The signed bytes, or `nil` when `payload` is not valid base64.
    public var payload: Data? {
        Data(base64Encoded: payloadBase64)
    }

    /// True for an envelope this build knows how to read. A *newer* envelope is refused
    /// rather than guessed at — the whole point of the wrapper is that its contents are
    /// interpreted exactly as signed.
    public var isSupportedVersion: Bool {
        version == Self.currentVersion
    }

    /// Recognizes an envelope in a fetched or on-disk body.
    ///
    /// Returns `nil` for a legacy flat catalog, which is not an error: both formats are
    /// served during the migration, and the caller falls back to the detached `.sig` path.
    /// A body that *looks* like an envelope but is malformed also returns `nil`, and the
    /// caller then fails it as an invalid catalog — either way nothing unverified is used.
    public static func decode(_ data: Data) -> CatalogEnvelope? {
        try? JSONDecoder().decode(CatalogEnvelope.self, from: data)
    }
}
