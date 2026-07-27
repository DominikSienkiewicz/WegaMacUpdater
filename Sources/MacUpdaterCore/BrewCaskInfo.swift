import Foundation

/// ARCH-04: the three views a single `brew info --cask --json=v2` run yields.
///
/// They were three separate calls producing three identical processes, distinguished only by
/// the parser applied afterwards. Keeping them together makes it structurally obvious that one
/// process answers all three questions.
public struct BrewCaskInfo: Equatable, Sendable {
    public var profiles: [CaskArtifactProfile]
    public var downloads: [CaskDownloadInfo]
    public var installations: [BrewCaskInstallationInfo]

    public init(
        profiles: [CaskArtifactProfile] = [],
        downloads: [CaskDownloadInfo] = [],
        installations: [BrewCaskInstallationInfo] = []
    ) {
        self.profiles = profiles
        self.downloads = downloads
        self.installations = installations
    }
}
