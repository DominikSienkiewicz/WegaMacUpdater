import Foundation

/// Fetches the page a feed points at instead of carrying its notes inline
/// (`<sparkle:releaseNotesLink>`), on demand — never during a scan.
///
/// What comes back is a whole web page written by a third party, so three things are
/// non-negotiable: HTTPS only (SEC-09), a hard byte cap before anything is decoded, and
/// `ReleaseNotesText` over the result. A page that fails any of them is `.unavailable`,
/// which the UI states — an empty body would read as "this release changed nothing".
public struct ReleaseNotesLinkFetcher: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// `truncated` is true when the character cap cut the text; the UI says so rather
        /// than letting the notes appear to stop mid-sentence for no reason.
        case notes(text: String, truncated: Bool)
        case unavailable
    }

    private let client: HTTPClient
    private let maxBytes: Int
    private let maxCharacters: Int

    public init(
        client: HTTPClient = .shared,
        maxBytes: Int = 256 * 1024,
        maxCharacters: Int = 20_000
    ) {
        self.client = client
        self.maxBytes = maxBytes
        self.maxCharacters = maxCharacters
    }

    public func text(at url: URL) async -> Outcome {
        guard url.scheme?.lowercased() == "https" else { return .unavailable }

        guard let response = try? await client.get(url), response.isOK else { return .unavailable }
        // Refused whole rather than truncated: cutting raw bytes can split a multi-byte
        // character or an entity, and a page this size is not notes anyway.
        guard response.data.count <= maxBytes else { return .unavailable }

        let plain = ReleaseNotesText.plain(fromHTML: String(decoding: response.data, as: UTF8.self))
        guard !plain.isEmpty else { return .unavailable }

        guard plain.count > maxCharacters else { return .notes(text: plain, truncated: false) }
        return .notes(text: String(plain.prefix(maxCharacters)), truncated: true)
    }
}
