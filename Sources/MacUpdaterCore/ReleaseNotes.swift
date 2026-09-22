import Foundation

/// What an update brings, in the two shapes update feeds actually publish: the release
/// entries themselves, or a link to a page carrying them.
///
/// Both may be present — a Sparkle appcast often has an inline `<description>` *and* a
/// `<sparkle:releaseNotesLink>`. Neither is a promise: a source that publishes nothing
/// yields `isEmpty`, and the UI then says nothing rather than inventing a "no changes"
/// it cannot know.
///
/// Every body here is already plain text. Sanitisation happens once, at the source that
/// produced the notes, so no view ever holds vendor HTML (UX-05).
public struct ReleaseNotes: Equatable, Sendable {
    /// Releases between the installed version and the newest one, newest first.
    public var history: ReleaseHistory
    /// A page carrying the notes, fetched only when the user asks for it. HTTPS only
    /// (SEC-09) — the parsers drop a plain-HTTP link before it ever reaches this type.
    public var link: URL?

    public init(history: ReleaseHistory, link: URL? = nil) {
        self.history = history
        self.link = link
    }

    /// One release's notes from a markup body — the shape a source that publishes a single
    /// release gives us (Wega's own self-update, a GitHub release with no predecessors).
    /// Markup that collapses to nothing yields no entry at all, not an empty one.
    public init(html: String, version: String = "", publishedAt: Date? = nil, link: URL? = nil) {
        let body = ReleaseNotesText.plain(fromHTML: html)
        let notes = body.isEmpty ? [] : [ReleaseNote(version: version, publishedAt: publishedAt, body: body)]
        self.init(history: ReleaseHistory(notes: notes, omitted: 0), link: link)
    }

    /// Nothing to show and nothing to fetch.
    public var isEmpty: Bool { history.notes.isEmpty && link == nil }

    /// Every entry's body, joined — the input `ReleaseNotesTriage` reads. Joining rather
    /// than taking the newest is the point: a security fix published two releases back is
    /// still a security fix the user has not got yet.
    public var plainText: String {
        history.notes.map(\.body).joined(separator: "\n")
    }
}

extension ReleaseNotes: Codable {
    private enum CodingKeys: String, CodingKey { case history, link }

    /// Tolerates the shape this field had before it became a type: a bare string of raw
    /// HTML. `ScanResultStore` decodes the whole snapshot with `try?`, so a failure here
    /// would not degrade one field — it would drop the entire last scan and leave the
    /// first launch after an update showing an empty list.
    ///
    /// The legacy shape recorded neither a version nor a date, so the entry claims
    /// neither. The next scan replaces it with a real history.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let legacy = try? single.decode(String.self) {
            self.init(html: legacy)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let history = try container.decode(ReleaseHistory.self, forKey: .history)
        let link = try container.decodeIfPresent(URL.self, forKey: .link)
        self.init(history: history, link: link)
    }
}
