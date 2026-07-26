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

        guard let url = AppEndpoints.shared.githubLatestReleaseURL(repo: mapping.repo) else { return nil }

        // ETag-conditional + opcjonalny token (SEC-08). UWAGA: GitHub zwalnia 304
        // z primary rate-limit TYLKO dla żądań autoryzowanych (Bearer). Bez tokenu
        // 304 oszczędza transfer, nie kwotę 60/h — token podnosi limit do 5000/h.
        let request = HTTPRequest(url: url, headers: GitHubAuth.headers(), enableETag: true)
        return VendorCheckPlan(request: request) { data in
            guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                return .decided(.failed)
            }

            // A draft/prerelease "latest" gives no stable newer build → treat as current.
            guard !release.draft, !release.prerelease else { return .decided(.upToDate) }

            let installed = app.version ?? ""
            guard !installed.isEmpty else { return .decided(.notApplicable) }
            return .candidate(VendorCandidate(
                latest: normalizeGitTag(release.tagName),
                installed: installed,
                recordedInstalled: app.version,
                source: .github(repo: mapping.repo),
                releaseNotes: release.body,  // FEAT-06: real notes for triage
                // REL-11: GitHub release tags are SemVer, so a prerelease must rank
                // below its own release instead of above it.
                scheme: .semver
            ))
        }
    }
}
