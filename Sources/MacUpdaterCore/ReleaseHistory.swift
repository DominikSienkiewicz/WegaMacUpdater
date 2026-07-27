import Foundation

/// One release's notes, ready for display: a version, when it was published, and a body with
/// every trace of markup removed.
public struct ReleaseNote: Equatable, Sendable, Identifiable {
    public let version: String
    public let publishedAt: Date?
    public let body: String

    public var id: String { version }

    public init(version: String, publishedAt: Date?, body: String) {
        self.version = version
        self.publishedAt = publishedAt
        self.body = body
    }
}

/// Everything published between the installed version and the newest one, newest first.
///
/// `omitted` is how many further releases the cap left out — reported rather than truncated
/// silently, so a long gap does not read as a short one.
public struct ReleaseHistory: Equatable, Sendable {
    public let notes: [ReleaseNote]
    public let omitted: Int

    public init(notes: [ReleaseNote], omitted: Int) {
        self.notes = notes
        self.omitted = omitted
    }
}

/// Fetches the cumulative "what's new" for Wega's own update — the answer to *what do I get if
/// I update*, which `WegaSelfUpdateChecker` (a single `latest` body) cannot give once more than
/// one release has passed.
///
/// Pure of `Bundle` and `NSWorkspace`, injectable `HTTPClient`, so the filtering, ordering,
/// sanitisation and capping are unit-tested without a network.
public struct ReleaseHistoryFetcher: Sendable {
    /// A missing history never blocks an update — notes are informative, not a gate. So the
    /// transport failure is its own answer, distinct from an empty history.
    public enum Outcome: Equatable, Sendable {
        case history(ReleaseHistory)
        case unavailable
    }

    private let repo: String
    private let client: HTTPClient

    public init(
        repo: String = "DominikSienkiewicz/WegaMacUpdater",
        client: HTTPClient = .shared
    ) {
        self.repo = repo
        self.client = client
    }

    public func notesNewerThan(_ installed: String, limit: Int = 10) async -> Outcome {
        guard let url = AppEndpoints.shared.githubReleasesURL(repo: repo) else { return .unavailable }

        guard let response = try? await client.get(
            url,
            headers: GitHubAuth.headers(),
            enableETag: true
        ), response.statusCode == 200,
            let releases = try? JSONDecoder().decode([GitHubRelease].self, from: response.data) else {
            return .unavailable
        }

        let newer = releases
            .filter { !$0.draft && !$0.prerelease }
            .map { (release: $0, version: normalizeGitTag($0.tagName)) }
            .filter { isUpgrade(installed: installed, latest: $0.version, scheme: .semver) }
            .sorted { compareVersions($0.version, $1.version, scheme: .semver) == .orderedDescending }

        let kept = newer.prefix(limit).map { entry in
            ReleaseNote(
                version: entry.version,
                publishedAt: entry.release.publishedAt.flatMap(Self.date(from:)),
                body: ReleaseNotesText.plain(fromHTML: entry.release.body ?? "")
            )
        }

        return .history(ReleaseHistory(notes: Array(kept), omitted: max(0, newer.count - kept.count)))
    }

    private static func date(from iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
