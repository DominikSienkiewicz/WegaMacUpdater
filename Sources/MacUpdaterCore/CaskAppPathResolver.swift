import Foundation
import WegaHelperKit

/// REL-03 — the one answer to "where is this cask's app bundle **right now**?".
///
/// Both upgrade paths need it and both used to compute it themselves: the window filled a
/// `caskIconPaths` map during a full scan and read it back at snapshot time, the background
/// updater ran its own copy of the same loop. The window's copy was the bug — a scan
/// restored from disk brings back the lists but not that map, so an upgrade started right
/// after launch snapshotted nothing and verified nothing. Resolving through here, fresh,
/// immediately before the snapshot, is what makes the rollback net independent of whether a
/// full scan happened in this session.
///
/// Directories and the existence check are injected for the same reason `StaleCaskDetector`
/// injects them: the resolution is pure and worth testing without a populated `/Applications`.
public struct CaskAppPathResolver {
    private let applicationsDirectory: URL
    private let userApplicationsDirectory: URL
    private let fileExists: (URL) -> Bool

    public init(
        applicationsDirectory: URL = SystemPaths.applicationsDirectory,
        userApplicationsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true),
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.applicationsDirectory = applicationsDirectory
        self.userApplicationsDirectory = userApplicationsDirectory
        self.fileExists = fileExists
    }

    /// Maps each cask token to the first of its app artifacts that actually exists on disk,
    /// system-wide install preferred over the per-user one. A cask whose artifacts are all
    /// missing — or that declares none — is absent from the result rather than mapped to a
    /// path that is not there; `CaskRollbackGuard` reads that absence as "cannot protect".
    ///
    /// - Parameter excludedTokens: tokens to skip, e.g. the drifted casks the outdated list
    ///   itself drops (a self-updating app whose bundle brew's metadata has not caught up with).
    public func appPaths(
        from installationInfo: [BrewCaskInstallationInfo],
        excluding excludedTokens: Set<String> = []
    ) -> [String: URL] {
        var paths: [String: URL] = [:]
        for info in installationInfo where !excludedTokens.contains(info.token) {
            for artifact in info.appArtifacts {
                let system = applicationsDirectory.appendingPathComponent(artifact)
                let user = userApplicationsDirectory.appendingPathComponent(artifact)
                if fileExists(system) {
                    paths[info.token] = system; break
                } else if fileExists(user) {
                    paths[info.token] = user; break
                }
            }
        }
        return paths
    }
}
