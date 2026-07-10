import Foundation

/// Refreshes the user-writable `AppCatalog` overlay from a remote JSON source.
///
/// `AppCatalog` already overlays a file at `AppCatalog.overlayURL` on top of the bundled
/// baseline, so new app mappings (a freshly self-updating IDE, a new GitHub-released app)
/// can land without shipping a new build — but nothing *fetched* that file. This is the
/// missing fetch: download the catalog, **validate it by decoding before touching disk**
/// (a malformed or hostile body must never clobber a good overlay), then write it
/// atomically. The source URL is injected, not hard-coded — wiring a canonical endpoint
/// and a trigger (launch / manual button) is a separate decision.
public struct CatalogRefresher: Sendable {
    public enum Outcome: Equatable, Sendable {
        case updated        // a new, valid catalog was written to disk
        case notModified    // the server answered 304 (ETag) — disk already current
        case invalid        // the body did not decode as an AppCatalog, or its signature was
                            // missing when one is required — disk left untouched
        /// The body is a well-formed catalog, but the detached signature does not verify
        /// against it (F5d). Two causes, cryptographically indistinguishable: the catalog was
        /// tampered with, or `raw.githubusercontent` served a fresh `app-catalog.json` beside
        /// a cached `app-catalog.json.sig` — they are separate CDN entries. Either way the
        /// disk is left untouched. Naming it "stale" would guess in the attacker's favour;
        /// naming it a mismatch says exactly what is known.
        case signatureMismatch
        case failed         // network or HTTP error — disk left untouched
    }

    private let source: URL
    private let destination: URL
    private let client: HTTPClient
    /// F5(a) — injected so the fail-closed branch is reachable from a test. Production
    /// passes the key compiled into the build.
    private let signatureVerifier: CatalogSignature

    public init(
        source: URL,
        destination: URL = AppCatalog.overlayURL,
        client: HTTPClient = .shared,
        signatureVerifier: CatalogSignature = .shared
    ) {
        self.source = source
        self.destination = destination
        self.client = client
        self.signatureVerifier = signatureVerifier
    }

    @discardableResult
    public func refresh() async -> Outcome {
        let response: HTTPResponse
        do {
            response = try await client.get(source, enableETag: true)
        } catch {
            return .failed
        }

        guard response.isOK else { return .failed }
        if response.notModified { return .notModified }

        // Validate before writing — a 200 with a garbage body must not replace the overlay.
        guard (try? JSONDecoder().decode(AppCatalog.self, from: response.data)) != nil else {
            return .invalid
        }

        // SEC-04: gdy publisher key jest skonfigurowany, wymagaj poprawnego
        // odłączonego podpisu Ed25519 (<source>.sig) nad dokładnymi bajtami ciała.
        // Bez konfiguracji klucza pomijamy (zachowanie jak dotąd — decode-only).
        var verifiedSignature: String?
        if signatureVerifier.isConfigured {
            guard let signatureBase64 = try? await fetchSignature() else { return .invalid }
            guard signatureVerifier.verify(data: response.data, signatureBase64: signatureBase64) else {
                return .signatureMismatch
            }
            verifiedSignature = signatureBase64
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try response.data.write(to: destination, options: .atomic)
            // F5(a) — persist the signature we just verified. `AppCatalog.loadOverlay` checks
            // it again on the next launch; an overlay written without one can never be loaded
            // again, which would silently strand the user on the bundled catalog.
            //
            // Order matters: the JSON lands first, so a crash between the two writes leaves a
            // catalog with no signature — rejected on read, falling back to the build. The
            // reverse order would leave a signature vouching for the *previous* bytes.
            let signaturePath = AppCatalog.signatureURL(for: destination)
            if let verifiedSignature {
                try Data(verifiedSignature.utf8).write(to: signaturePath, options: .atomic)
            } else {
                // Unsigned mode: a leftover `.sig` from a signed build would vouch for bytes
                // that no longer exist, and `loadOverlay` would reject the fresh catalog.
                try? FileManager.default.removeItem(at: signaturePath)
            }
            return .updated
        } catch {
            return .failed
        }
    }

    /// Sibling detached-signature URL: `…/app-catalog.json` → `…/app-catalog.json.sig`.
    private var signatureURL: URL { source.appendingPathExtension("sig") }

    /// Fetches the detached base64 signature; throws if missing/unreadable so the
    /// caller treats it as `.invalid` (fail-closed when signing is required).
    private func fetchSignature() async throws -> String {
        let response = try await client.get(signatureURL)
        guard response.isOK, let signature = String(data: response.data, encoding: .utf8) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return signature
    }
}
