import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("Releases endpoint")
struct ReleasesEndpointTests {
    @Test func fillsTheRepositoryPlaceholder() {
        let url = AppEndpoints.shared.githubReleasesURL(repo: "owner/repo")
        #expect(url?.absoluteString.contains("owner/repo") == true)
        #expect(url?.host == "api.github.com")
    }

    /// SEC-08: a templated override must be https and land on an allowlisted host, or the
    /// bundled baseline stands.
    @Test func rejectsAnOverrideOffTheAllowlist() {
        let baseline = AppEndpoints.shared
        let overridden = baseline.overlaying(
            AppEndpointsOverlay(
                jetbrainsReleases: nil,
                chatgptAppcast: nil,
                googleDriveOmaha: nil,
                caskDatabase: nil,
                appCatalog: nil,
                githubLatestRelease: nil,
                githubReleases: "https://evil.example.com/repos/{repo}/releases",
                synologyChangeLog: nil,
                antigravityUpdate: nil,
                parallelsUpdates: nil,
                postmanUpdate: nil,
                discordUpdate: nil,
                signalUpdate: nil,
                chromeVersions: nil,
                homebrewWebsite: nil,
                homebrewInstallCommand: nil,
                githubReleasesPage: nil,
                googleDriveDownload: nil,
                projectRepository: nil,
                projectIssues: nil,
                authorLinkedIn: nil,
                masRepository: nil
            )
        )
        #expect(overridden.githubReleases == baseline.githubReleases)
    }
}
