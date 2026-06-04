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

    public func check(app: ApplicationInfo) async -> ManualOutdatedApp? {
        guard let bundleId = app.bundleIdentifier,
              let mapping = repos[bundleId] else { return nil }

        let urlString = "https://api.github.com/repos/\(mapping.repo)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }

        // ETag-conditional: a 304 reuses the cached body and does not count against
        // GitHub's unauthenticated 60-req/h rate limit.
        guard let response = try? await client.get(url, headers: ["Accept": "application/vnd.github+json"], enableETag: true),
              response.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: response.data),
              !release.draft, !release.prerelease else { return nil }

        let latest = normalizeGitTag(release.tagName)
        let installed = app.version ?? ""
        guard !installed.isEmpty, isUpgrade(installed: installed, latest: latest) else { return nil }

        return ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version,
            availableVersion: latest,
            source: .github(repo: mapping.repo)
        )
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
