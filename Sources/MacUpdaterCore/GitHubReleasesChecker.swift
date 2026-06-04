import Foundation

public struct GitHubReleasesChecker: Sendable {
    private let session: URLSession
    private let repos: [String: GitHubCatalogEntry]

    public init(
        session: URLSession = .shared,
        repos: [String: GitHubCatalogEntry] = AppCatalog.shared.githubRepos
    ) {
        self.session = session
        self.repos = repos
    }

    public func check(app: ApplicationInfo) async -> ManualOutdatedApp? {
        guard let bundleId = app.bundleIdentifier,
              let mapping = repos[bundleId] else { return nil }

        let urlString = "https://api.github.com/repos/\(mapping.repo)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WegaMacUpdater/1.0", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadRevalidatingCacheData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
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
