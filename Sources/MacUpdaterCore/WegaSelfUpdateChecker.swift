import Foundation
import WegaHelperKit

/// Checks whether a newer Wega release is available — Wega dogfooding its own machinery.
///
/// Instead of embedding Sparkle, Wega self-updates the same way it tracks other
/// GitHub-released apps: it asks the GitHub Releases API for the latest tag, compares it
/// against `AppMetadata.version` with the shared `VersionComparison` logic, and points at
/// the published installer asset (preferring the pinnable `.pkg`, falling back to the
/// `.dmg` — see `SelfUpdatePlanner.preferredAssetName`, SEC-04). The UI surfaces this in
/// the Info tab and opens the asset; no extra infrastructure, no appcast to host.
public struct WegaSelfUpdateChecker: Sendable {
    public enum Result: Equatable, Sendable {
        case upToDate
        /// `notes` = release body, for advisory triage (FEAT-06).
        case updateAvailable(version: String, assetURL: URL, releaseURL: URL, notes: String)
        case failed

        /// The version the offered asset claims to be, or `nil` when nothing is offered.
        /// SEC-04 — the downloaded payload is verified against it, so a signed-but-stale
        /// artifact cannot be served in place of the release the user was shown.
        public var availableVersion: String? {
            if case .updateAvailable(let version, _, _, _) = self { return version }
            return nil
        }
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
        guard let url = AppEndpoints.shared.githubLatestReleaseURL(repo: repo) else {
            return .failed
        }

        guard let response = try? await client.get(
            url,
            headers: GitHubAuth.headers(),   // SEC-08: dokłada Bearer, jeśli token w Keychain
            enableETag: true
        ), response.statusCode == 200,
            let release = try? JSONDecoder().decode(GitHubRelease.self, from: response.data) else {
            return .failed
        }

        // A draft/prerelease "latest" is not a stable update target.
        guard !release.draft, !release.prerelease else { return .upToDate }

        let latest = normalizeGitTag(release.tagName)
        // REL-11: GitHub release tags are SemVer — compare under `.semver`, matching
        // `GitHubReleasesChecker`.
        guard isUpgrade(installed: currentVersion, latest: latest, scheme: .semver) else { return .upToDate }

        // SEC-04: prefer the .pkg — the only channel with a full publisher pin — and fall
        // back to the .dmg. The preference itself lives in `SelfUpdatePlanner`.
        let assets = release.assets ?? []
        let preferredName = SelfUpdatePlanner.preferredAssetName(from: assets.map(\.name))
        let asset = assets.first { $0.name == preferredName }
        guard let asset,
              let assetURL = URL(string: asset.browserDownloadURL),
              let htmlURL = release.htmlURL,
              let releaseURL = URL(string: htmlURL) else {
            return .failed
        }

        return .updateAvailable(version: latest, assetURL: assetURL, releaseURL: releaseURL, notes: release.body ?? "")
    }
}
