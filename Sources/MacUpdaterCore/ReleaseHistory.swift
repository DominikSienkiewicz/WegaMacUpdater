import Foundation

/// One release's notes, ready for display: a version, when it was published, and a body with
/// every trace of markup removed.
public struct ReleaseNote: Codable, Equatable, Sendable, Identifiable {
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
public struct ReleaseHistory: Codable, Equatable, Sendable {
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
            let releases = GitHubReleaseHistory.stableReleases(from: response.data) else {
            return .unavailable
        }

        return .history(GitHubReleaseHistory.history(releases, newerThan: installed, limit: limit))
    }
}
