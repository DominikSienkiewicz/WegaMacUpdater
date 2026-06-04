import Foundation

/// Checks whether a newer Wega release is available — Wega dogfooding its own machinery.
///
/// Instead of embedding Sparkle, Wega self-updates the same way it tracks other
/// GitHub-released apps: it asks the GitHub Releases API for the latest tag, compares it
/// against `AppMetadata.version` with the shared `VersionComparison` logic, and points at
/// the published installer asset (preferring the `.dmg`, falling back to the `.pkg`). The
/// UI surfaces this in the Info tab and opens the asset; no extra infrastructure, no
/// appcast to host.
public struct WegaSelfUpdateChecker: Sendable {
    public enum Result: Equatable, Sendable {
        case upToDate
        case updateAvailable(version: String, assetURL: URL, releaseURL: URL)
        case failed
    }

    private let repo: String
    private let currentVersion: String
    private let client: HTTPClient

    public init(
        repo: String = "DominikSienkiewicz/WegaMacUpdater",
        currentVersion: String = AppMetadata.version,
        client: HTTPClient = .shared
    ) {
        self.repo = repo
        self.currentVersion = currentVersion
        self.client = client
    }

    public func check() async -> Result {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed
        }

        guard let response = try? await client.get(
            url,
            headers: ["Accept": "application/vnd.github+json"],
            enableETag: true
        ), response.statusCode == 200,
            let release = try? JSONDecoder().decode(Release.self, from: response.data) else {
            return .failed
        }

        // A draft/prerelease "latest" is not a stable update target.
        guard !release.draft, !release.prerelease else { return .upToDate }

        let latest = normalizeGitTag(release.tagName)
        guard isUpgrade(installed: currentVersion, latest: latest) else { return .upToDate }

        // Prefer the drag-to-Applications .dmg, fall back to the .pkg installer.
        let asset = release.assets.first { $0.name.hasSuffix(".dmg") }
            ?? release.assets.first { $0.name.hasSuffix(".pkg") }
        guard let asset,
              let assetURL = URL(string: asset.browserDownloadURL),
              let releaseURL = URL(string: release.htmlURL) else {
            return .failed
        }

        return .updateAvailable(version: latest, assetURL: assetURL, releaseURL: releaseURL)
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let htmlURL: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
            case htmlURL = "html_url"
            case assets
        }
    }
}
