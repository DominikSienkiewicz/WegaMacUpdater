import Foundation
import CryptoKit

/// Ed25519 verification for remotely-fetched / user-overlaid configuration
/// (**SEC-04**, closes A2 / A3 / I-5). Turns "writable config = attack surface"
/// into "verifiable, signed config" — a trust feature no competitor ships.
///
/// Model: each config document (`app-catalog.json`, `endpoints.json`) ships with
/// a DETACHED base64 Ed25519 signature over its exact bytes, at a sibling
/// `<file>.sig`. The app embeds the publisher PUBLIC key and verifies before
/// applying any overlay.
///
/// Roll-out: if no key is configured (dev/ad-hoc), verification is skipped and
/// callers fall back to their prior decode-only validation — so the feature is
/// opt-in and never bricks an unsigned dev setup. Once a key is set, every
/// override must be signed (fail-closed).
///
/// The key arrives through an initialiser rather than being read out of a `static let`
/// inside `verify`. That is what makes the fail-closed branch testable at all: before this,
/// nothing could construct a *configured* verifier, so the only behaviour a test could
/// observe was "unconfigured, refuses everything".
public struct CatalogSignature: Sendable {
    /// The literal meaning "no publisher key yet" — named once, compared once.
    ///
    /// It used to be a string literal repeated inside `isConfigured`. A find-and-replace
    /// that pasted a real key over *both* occurrences reduced the check to `key != key`:
    /// permanently false, every signature check in the app silently off, while verifying the
    /// same signature by hand with `openssl` passed. Pinned by `CatalogSignatureTests`.
    public static let unconfiguredPlaceholder = "REPLACE_ED25519_PUBKEY"

    // KONFIGURACJA (Dominik): base64 SUROWEGO klucza publicznego Ed25519 (32 bajty).
    //   let key = Curve25519.Signing.PrivateKey()
    //   key.publicKey.rawRepresentation.base64EncodedString()   // ← tutaj, i TYLKO tutaj
    // Podpisy generuj kluczem prywatnym nad bajtami pliku → base64 → <plik>.sig
    public static let publicKeyBase64 = "hIBhd9jCe39fbyQQimwzJqgwW79/Z3L7GRPbPfr+4zQ="

    /// The verifier the app uses, built from the key compiled into this build.
    public static let shared = CatalogSignature(publicKeyBase64: publicKeyBase64)

    /// `nil` when no usable key is configured — the placeholder is still in place, or the
    /// value is not a well-formed 32-byte Ed25519 public key. Both count as unconfigured:
    /// a key we cannot parse is no safer to trust than no key at all.
    private let publicKey: Curve25519.Signing.PublicKey?

    public init(publicKeyBase64: String) {
        let trimmed = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != Self.unconfiguredPlaceholder,
              let keyData = Data(base64Encoded: trimmed),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            publicKey = nil
            return
        }
        publicKey = key
    }

    /// True once a real publisher key is set (gates the fail-closed paths).
    public var isConfigured: Bool { publicKey != nil }

    /// Verifies a detached base64 Ed25519 signature over `data`. Returns false on any
    /// decode/verify failure (fail-closed). Also false when unconfigured — callers must
    /// check `isConfigured` to decide whether verification is *required*, rather than
    /// reading `false` as "bad signature".
    public func verify(data: Data, signatureBase64: String) -> Bool {
        guard let publicKey,
              let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    // MARK: - Compatibility surface
    //
    // Call sites (`CatalogRefresher`, `AppEndpoints`, `AppCatalog`) reach for the shipped
    // key, not an injected one. Keeping these static forwards makes the seam purely
    // additive: production keeps its single key, tests build their own.

    public static var isConfigured: Bool { shared.isConfigured }

    public static func verify(data: Data, signatureBase64: String) -> Bool {
        shared.verify(data: data, signatureBase64: signatureBase64)
    }
}
