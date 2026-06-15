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
public enum CatalogSignature {
    // TODO(Dominik): wstaw base64 SUROWEGO klucza publicznego Ed25519 (32 bajty).
    //   let key = Curve25519.Signing.PrivateKey()
    //   key.publicKey.rawRepresentation.base64EncodedString()   // ← tutaj
    // Podpisy generuj kluczem prywatnym nad bajtami pliku → base64 → <plik>.sig
    public static let publicKeyBase64 = "REPLACE_ED25519_PUBKEY"

    /// True once a real publisher key is set (gates the fail-closed paths).
    public static var isConfigured: Bool { publicKeyBase64 != "REPLACE_ED25519_PUBKEY" }

    /// Verifies a detached base64 Ed25519 signature over `data`. Returns false on
    /// any decode/verify failure (fail-closed). No-ops to false if unconfigured —
    /// callers must check `isConfigured` to decide whether verification is required.
    public static func verify(data: Data, signatureBase64: String) -> Bool {
        guard isConfigured,
              let keyData = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }
}
