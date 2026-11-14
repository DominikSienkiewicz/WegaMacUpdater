import Foundation
import WegaHelperKit

/// One downloadable artifact of a published release.
///
/// The checker reports every asset a release carries; deciding *which* one to use, and how
/// to apply it, belongs to ``SelfUpdatePlanner``. Splitting the two is what lets the UI show
/// the whole release while a single function states the security ordering (SEC-04) and the
/// install-vs-open decision.
public struct ReleaseAsset: Equatable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    /// Lowercased file extension — the only property the choice depends on.
    public var kind: String { url.pathExtension.lowercased() }
}

/// Checks whether a newer Wega release is available — Wega dogfooding its own machinery.
///
/// Instead of embedding Sparkle, Wega self-updates the same way it tracks other
/// GitHub-released apps: it asks the GitHub Releases API for the latest tag, compares it
/// against `AppMetadata.version` with the shared `VersionComparison` logic, and reports every
/// asset the release published. A release carrying nothing Wega can pin — no `.pkg` and no
/// `.dmg` — is reported as `.failed` rather than offered (SEC-04; the ordering itself lives
/// in `SelfUpdatePlanner.preferredAsset`). The UI surfaces this in the Info tab; no extra
/// infrastructure, no appcast to host.
public struct WegaSelfUpdateChecker: Sendable {
    public enum Result: Equatable, Sendable {
        case upToDate
        /// `notes` = release body, for advisory triage (FEAT-06). `assets` is every artifact
        /// the release published, in publication order; the planner picks one.
        case updateAvailable(version: String, assets: [ReleaseAsset], releaseURL: URL, notes: String)
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

        let assets = (release.assets ?? []).compactMap { asset -> ReleaseAsset? in
            guard let url = URL(string: asset.browserDownloadURL) else { return nil }
            return ReleaseAsset(name: asset.name, url: url)
        }
        // SEC-04: a release that published nothing pinnable is not an update target. The
        // full asset list still travels to the UI; what is refused here is *offering* a
        // release Wega could not verify. The ordering is asked for, never restated.
        guard SelfUpdatePlanner.preferredAsset(from: assets) != nil,
              let htmlURL = release.htmlURL,
              let releaseURL = URL(string: htmlURL) else {
            return .failed
        }

        return .updateAvailable(
            version: latest,
            assets: assets,
            releaseURL: releaseURL,
            notes: release.body ?? ""
        )
    }
}
