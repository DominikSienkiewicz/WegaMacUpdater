import Foundation

public struct GitHubReleasesChecker: VendorUpdateChecker {
    public let client: HTTPClient
    private let repos: [String: GitHubCatalogEntry]

    public init(
        client: HTTPClient = .shared,
        repos: [String: GitHubCatalogEntry] = AppCatalog.shared.githubRepos
    ) {
        self.client = client
        self.repos = repos
    }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard let bundleId = app.bundleIdentifier,
              let mapping = repos[bundleId] else { return nil }

        guard let url = AppEndpoints.shared.githubReleasesURL(repo: mapping.repo) else { return nil }

        // ETag-conditional + opcjonalny token (SEC-08). UWAGA: GitHub zwalnia 304
        // z primary rate-limit TYLKO dla żądań autoryzowanych (Bearer). Bez tokenu
        // 304 oszczędza transfer, nie kwotę 60/h — token podnosi limit do 5000/h.
        let request = HTTPRequest(url: url, headers: GitHubAuth.headers(), enableETag: true)
        return VendorCheckPlan(request: request) { data in
            // The list endpoint, not `/releases/latest`: one request either way, but this one
            // also carries every release the user is behind, which is the question the row
            // actually has to answer. Drafts and prereleases are filtered here rather than by
            // GitHub, and REL-11's SemVer ordering decides which release is newest.
            guard let releases = GitHubReleaseHistory.stableReleases(from: data) else {
                return .decided(.failed)
            }
            guard let newest = GitHubReleaseHistory.newest(releases) else { return .decided(.upToDate) }

            let installed = app.version ?? ""
            guard !installed.isEmpty else { return .decided(.notApplicable) }
            return .candidate(VendorCandidate(
                latest: normalizeGitTag(newest.tagName),
                installed: installed,
                recordedInstalled: app.version,
                source: .github(repo: mapping.repo, selfUpdates: mapping.selfUpdates),
                releaseNotes: ReleaseNotes(
                    history: GitHubReleaseHistory.history(releases, newerThan: installed, limit: 10)
                ),
                // REL-11: GitHub release tags are SemVer, so a prerelease must rank
                // below its own release instead of above it.
                scheme: .semver
            ))
        }
    }
}
