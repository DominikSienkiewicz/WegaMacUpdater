import Foundation

public struct GitHubReleasesChecker: Sendable {
    private struct Mapping {
        let repo: String
        let caskToken: String
    }

    private static let repos: [String: Mapping] = [
        "com.microsoft.VSCode":         Mapping(repo: "microsoft/vscode",              caskToken: "visual-studio-code"),
        "md.obsidian":                  Mapping(repo: "obsidianmd/obsidian-releases",  caskToken: "obsidian"),
        "com.knollsoft.Rectangle":      Mapping(repo: "rxhanson/Rectangle",            caskToken: "rectangle"),
        "com.lwouis.alt-tab-macos":     Mapping(repo: "lwouis/alt-tab-macos",          caskToken: "alt-tab"),
        "eu.exelban.Stats":             Mapping(repo: "exelban/Stats",                 caskToken: "stats"),
        "org.p0deje.Maccy":             Mapping(repo: "p0deje/Maccy",                  caskToken: "maccy"),
        "me.guillaumeb.MonitorControl": Mapping(repo: "MonitorControl/MonitorControl", caskToken: "monitorcontrol"),
        "com.linearmouse.linearmouse":  Mapping(repo: "linearmouse/linearmouse",       caskToken: "linearmouse"),
        "com.colliderli.iina":          Mapping(repo: "iina/iina",                     caskToken: "iina"),
        "fr.handbrake.HandBrake":       Mapping(repo: "HandBrake/HandBrake",           caskToken: "handbrake"),
        "com.aone.keka":                Mapping(repo: "aonez/Keka",                    caskToken: "keka"),
        "com.github.GitHubClient":      Mapping(repo: "desktop/desktop",               caskToken: "github"),
    ]

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(app: ApplicationInfo) async -> ManualOutdatedApp? {
        guard let bundleId = app.bundleIdentifier,
              let mapping = Self.repos[bundleId] else { return nil }

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
