import Foundation

public enum CleanupProjectRootRejection: Equatable, Sendable {
    case protectedLocation
    case alreadyListed
}

/// The folders Cleanup reads version files from. Stored as absolute path strings; without a stored
/// value the list is `~/Dev`, while an explicitly empty list stays empty. Paths are compared by
/// scalar-split components.
public enum CleanupProjectRoots {
    public static let defaultsKey = "cleanup.projectRoots"

    public static func roots(from defaults: UserDefaults, home: URL) -> [URL] {
        guard let stored = defaults.object(forKey: defaultsKey) as? [String] else {
            return [home.appending(path: "Dev", directoryHint: .isDirectory)]
        }
        return stored.filter(CleanupPathText.isAbsolute).map(directory)
    }

    /// Rejects a root `ProtectedLocationGuard.checkSubtree` refuses, which includes one that
    /// contains a protected root, so `~` and `~/Library` cannot be listed.
    public static func add(
        _ url: URL, to defaults: UserDefaults, home: URL, protectedLocations: ProtectedLocationGuard
    ) -> CleanupProjectRootRejection? {
        guard (try? protectedLocations.checkSubtree(url)) != nil else { return .protectedLocation }
        let current = roots(from: defaults, home: home)
        let candidate = CleanupPathText.components(of: url.path)
        guard !current.contains(where: { CleanupPathText.components(of: $0.path) == candidate }) else {
            return .alreadyListed
        }
        store(current + [directory(url.path)], in: defaults)
        return nil
    }

    public static func remove(_ url: URL, from defaults: UserDefaults, home: URL) {
        let target = CleanupPathText.components(of: url.path)
        store(roots(from: defaults, home: home).filter { CleanupPathText.components(of: $0.path) != target }, in: defaults)
    }

    private static func directory(_ path: String) -> URL {
        URL(filePath: "/" + CleanupPathText.components(of: path).joined(separator: "/"), directoryHint: .isDirectory)
    }

    private static func store(_ roots: [URL], in defaults: UserDefaults) {
        defaults.set(roots.map(\.path), forKey: defaultsKey)
    }
}
