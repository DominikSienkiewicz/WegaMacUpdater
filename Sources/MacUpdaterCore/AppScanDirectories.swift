import Foundation

/// The directories scanned for installed apps: `/Applications`, `~/Applications`,
/// and each of their immediate non-`.app` subfolders (e.g. `/Applications/JetBrains/`).
public enum AppScanDirectories {
    public static func all(fileManager: FileManager = .default) -> [URL] {
        let roots: [URL] = [
            SystemPaths.applicationsDirectory,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var dirs: [URL] = []
        for root in roots {
            guard (try? root.checkResourceIsReachable()) == true else { continue }
            dirs.append(root)
            let children = (try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
            )) ?? []
            for child in children where child.pathExtension != "app" {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    dirs.append(child)
                }
            }
        }
        return dirs
    }

    /// On-disk cache for the Homebrew cask database.
    public static var caskDatabaseCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/casks.json")
    }
}
