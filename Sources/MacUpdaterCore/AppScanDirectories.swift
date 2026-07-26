import Foundation
import WegaHelperKit

/// The directories scanned for installed apps: the built-in roots `/Applications` and
/// `~/Applications`, any user-added roots, and their non-`.app` subfolders down to a
/// controlled recursion depth (e.g. `/Applications/JetBrains/`).
///
/// UX-16: the roots, exclusions and depth come from a `ScanConfiguration`. The returned list
/// is deduplicated by **resolved** (symlink-followed) path so that a directory and a symlink
/// pointing at it collapse to one scan entry — otherwise, because installation identity is
/// purely lexical (REL-16), the same app reached through two paths would appear twice. The
/// *returned* URLs stay lexical (unresolved): only the dedup comparison follows symlinks, so
/// scanned paths keep matching `InstallationIdentity`.
public enum AppScanDirectories {
    public static func all(
        configuration: ScanConfiguration = ScanConfiguration(),
        fileManager: FileManager = .default
    ) -> [URL] {
        let roots: [URL] = [
            SystemPaths.applicationsDirectory,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ] + configuration.userDirectories

        let excludedPaths = configuration.exclusions.map(resolvedPath)
        var dirs: [URL] = []
        var seen = Set<String>()

        func isExcluded(_ url: URL) -> Bool {
            let path = resolvedPath(url)
            return excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        func collect(_ directory: URL, depth: Int) {
            guard (try? directory.checkResourceIsReachable()) == true else { return }
            guard !isExcluded(directory) else { return }
            guard seen.insert(resolvedPath(directory)).inserted else { return }
            dirs.append(directory)
            guard depth > 0 else { return }
            let children = (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
            )) ?? []
            for child in children where child.pathExtension != "app" {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    collect(child, depth: depth - 1)
                }
            }
        }

        for root in roots {
            collect(root, depth: configuration.recursionDepth)
        }
        return dirs
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// On-disk cache for the Homebrew cask database.
    public static var caskDatabaseCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/casks.json")
    }
}
