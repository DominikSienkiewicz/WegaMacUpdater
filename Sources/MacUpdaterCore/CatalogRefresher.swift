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
        /// SEC-07 — the document is well-formed and correctly signed, but its generation is
        /// *lower* than one this installation already accepted. A valid signature over old
        /// bytes is exactly what a replay looks like, so it is refused by name rather than
        /// folded into `.invalid`.
        case replayRejected
        /// SEC-07 — the document declares a catalog schema this build does not implement.
        /// Refused loudly; before this it decoded as a valid, *empty* catalog and quietly
        /// switched every catalog-driven checker off.
        case unsupportedSchema
        case failed         // network or HTTP error — disk left untouched
    }

    private let source: URL
    private let destination: URL
    private let client: HTTPClient
    /// F5(a) — injected so the fail-closed branch is reachable from a test. Production
    /// passes the key compiled into the build.
    private let signatureVerifier: CatalogSignature
    /// SEC-07 — the replay watermark, injected so a test can start from a known generation.
    private let generations: CatalogGenerationLedger

    public init(
        source: URL,
        destination: URL = AppCatalog.overlayURL,
        client: HTTPClient = .shared,
        signatureVerifier: CatalogSignature = .shared,
        generations: CatalogGenerationLedger = CatalogGenerationLedger()
    ) {
        self.source = source
        self.destination = destination
        self.client = client
        self.signatureVerifier = signatureVerifier
        self.generations = generations
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

        // SEC-07 — the wire carries either the one-document envelope or the legacy flat
        // catalog beside a detached `.sig`. Unwrapping reduces both to the same thing: the
        // exact bytes a signature has to cover.
        let embeddedSignature: String?
        let signedBytes: Data
        if let envelope = CatalogEnvelope.decode(response.data) {
            // A wrapper version from the future is the same story as a catalog schema from
            // the future, and deserves the same answer: update Wega, don't guess at it.
            guard envelope.isSupportedVersion else { return .unsupportedSchema }
            guard let payload = envelope.payload else { return .invalid }
            signedBytes = payload
            embeddedSignature = envelope.signatureBase64
        } else {
            signedBytes = response.data
            embeddedSignature = nil
        }

        // Validate before writing — a 200 with a garbage body must not replace the overlay.
        // Decoding is also what enforces `schemaVersion`, so a document in a format this
        // build does not implement is refused here instead of landing as an empty catalog.
        let catalog: AppCatalog
        do {
            catalog = try JSONDecoder().decode(AppCatalog.self, from: signedBytes)
        } catch {
            return Self.isSchemaRefusal(error) ? .unsupportedSchema : .invalid
        }

        // SEC-04: gdy publisher key jest skonfigurowany, wymagaj poprawnego podpisu Ed25519
        // nad dokładnymi bajtami katalogu — z koperty albo z pliku <source>.sig.
        // Bez konfiguracji klucza pomijamy (zachowanie jak dotąd — decode-only).
        var verifiedSignature: String?
        if signatureVerifier.isConfigured {
            let candidate: String?
            if let embeddedSignature {
                candidate = embeddedSignature
            } else {
                candidate = try? await fetchSignature()
            }
            guard let signatureBase64 = candidate else { return .invalid }
            guard signatureVerifier.verify(data: signedBytes, signatureBase64: signatureBase64) else {
                return .signatureMismatch
            }
            verifiedSignature = signatureBase64
        }

        // SEC-07 — replay/downgrade, checked *after* the signature: a generation nobody
        // signed is not evidence of anything, and acting on one would let an unauthenticated
        // body decide whether a real update gets through.
        guard generations.accepts(catalog.generation) else { return .replayRejected }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // The *signed* bytes land on disk, unwrapped. `loadOverlay` re-verifies the
            // detached signature beside them, so the on-disk layout stays what it has always
            // been — the envelope solves a CDN problem, and there is no CDN here.
            try signedBytes.write(to: destination, options: .atomic)
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
            // Only after the bytes are safely down: a watermark raised over a catalog that
            // failed to land would refuse the retry that would have fixed it.
            generations.record(catalog.generation)
            return .updated
        } catch {
            return .failed
        }
    }

    /// Distinguishes "we do not implement this format" from "this is not a catalog", so the
    /// user is told which of the two happened.
    private static func isSchemaRefusal(_ error: Error) -> Bool {
        guard case DecodingError.dataCorrupted(let context) = error else { return false }
        return context.codingPath.contains { $0.stringValue == "schemaVersion" }
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
