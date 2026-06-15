import Foundation

public struct GitHubReleasesChecker: Sendable {
    private let client: HTTPClient
    private let repos: [String: GitHubCatalogEntry]

    public init(
        client: HTTPClient = .shared,
        repos: [String: GitHubCatalogEntry] = AppCatalog.shared.githubRepos
    ) {
        self.client = client
        self.repos = repos
    }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard let bundleId = app.bundleIdentifier,
              let mapping = repos[bundleId] else { return .notApplicable }

        guard let url = AppEndpoints.shared.githubLatestReleaseURL(repo: mapping.repo) else { return .notApplicable }

        // ETag-conditional + opcjonalny token (SEC-08). UWAGA: GitHub zwalnia 304
        // z primary rate-limit TYLKO dla żądań autoryzowanych (Bearer). Bez tokenu
        // 304 oszczędza transfer, nie kwotę 60/h — token podnosi limit do 5000/h.
        guard let response = try? await client.get(url, headers: GitHubAuth.headers(), enableETag: true) else {
            return .unavailable
        }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: response.data) else {
            return .failed
        }

        // A draft/prerelease "latest" gives no stable newer build → treat as current.
        guard !release.draft, !release.prerelease else { return .upToDate }

        let installed = app.version ?? ""
        guard !installed.isEmpty else { return .notApplicable }
        let latest = normalizeGitTag(release.tagName)
        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version,
            availableVersion: latest,
            source: .github(repo: mapping.repo)
        ))
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
    }
}
