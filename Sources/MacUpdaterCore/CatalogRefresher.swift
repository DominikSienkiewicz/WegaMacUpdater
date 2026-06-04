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
        case invalid        // the body did not decode as an AppCatalog — disk left untouched
        case failed         // network or HTTP error — disk left untouched
    }

    private let source: URL
    private let destination: URL
    private let client: HTTPClient

    public init(
        source: URL,
        destination: URL = AppCatalog.overlayURL,
        client: HTTPClient = .shared
    ) {
        self.source = source
        self.destination = destination
        self.client = client
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

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try response.data.write(to: destination, options: .atomic)
            return .updated
        } catch {
            return .failed
        }
    }
}
