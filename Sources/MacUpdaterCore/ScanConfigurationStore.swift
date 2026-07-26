import Foundation

/// Persists the UX-16 scan configuration in `UserDefaults` and resolves it back into a
/// `ScanConfiguration` for the scan.
///
/// User directories are stored as **security-scoped bookmarks** (AC: "przez security-scoped
/// bookmarks") so a user-chosen location survives relaunch and a rename. WegaMacUpdater is
/// not sandboxed, so a resolved directory is readable without holding a security scope —
/// `resolvedConfiguration` therefore returns paths without engaging one, which means there is
/// no scope to balance on the scan hot path. Should the app ever be sandboxed, the bookmarks
/// already carry `.withSecurityScope` and only the access start/stop would need adding.
///
/// Every function takes an injectable `UserDefaults` (mirroring `DownloadGate.Configuration`)
/// so it is testable without touching `.standard`, and is intentionally non-isolated so the
/// scan seams (`buildScanDirs`, `ManualUpdateScanner`) can read the configuration from any
/// context.
public enum ScanConfigurationStore {
    public static let userDirectoryBookmarksKey = "wega.scan.userDirectoryBookmarks"
    public static let exclusionPathsKey = "wega.scan.exclusionPaths"
    public static let recursionDepthKey = "wega.scan.recursionDepth"

    // MARK: - Reads

    public static func recursionDepth(from defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: recursionDepthKey) != nil else {
            return ScanConfiguration.defaultRecursionDepth
        }
        return ScanConfiguration.clamp(defaults.integer(forKey: recursionDepthKey))
    }

    public static func exclusionPaths(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: exclusionPathsKey) ?? []
    }

    public static func userDirectoryBookmarks(from defaults: UserDefaults = .standard) -> [Data] {
        (defaults.array(forKey: userDirectoryBookmarksKey) as? [Data]) ?? []
    }

    /// Resolves the stored bookmarks to directory URLs, silently dropping any that no longer
    /// resolve (deleted, unplugged volume, corrupt bookmark) so a stale entry can't break a scan.
    public static func resolvedUserDirectories(from defaults: UserDefaults = .standard) -> [URL] {
        userDirectoryBookmarks(from: defaults).compactMap(resolveDirectory(bookmark:))
    }

    public static func resolvedConfiguration(from defaults: UserDefaults = .standard) -> ScanConfiguration {
        ScanConfiguration(
            userDirectories: resolvedUserDirectories(from: defaults),
            exclusions: exclusionPaths(from: defaults).map { URL(fileURLWithPath: $0, isDirectory: true) },
            recursionDepth: recursionDepth(from: defaults)
        )
    }

    // MARK: - Writes

    /// Stores `url` as a bookmark. Deduplicated by resolved path so the same folder — or a
    /// symlink to one already stored — is never added twice. Returns `false` when the folder
    /// is already present or a bookmark could not be created.
    @discardableResult
    public static func addUserDirectory(
        _ url: URL,
        to defaults: UserDefaults = .standard,
        creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    ) -> Bool {
        let alreadyStored = resolvedUserDirectories(from: defaults).map(Self.resolvedPath)
        guard !alreadyStored.contains(Self.resolvedPath(url)) else { return false }
        guard let bookmark = makeBookmark(for: url, options: creationOptions) else { return false }
        var bookmarks = userDirectoryBookmarks(from: defaults)
        bookmarks.append(bookmark)
        defaults.set(bookmarks, forKey: userDirectoryBookmarksKey)
        return true
    }

    /// Removes the stored directory whose resolved path matches `path`. Bookmarks that no
    /// longer resolve are dropped in the same pass.
    public static func removeUserDirectory(resolvedPath path: String, from defaults: UserDefaults = .standard) {
        let kept = userDirectoryBookmarks(from: defaults).filter { bookmark in
            guard let url = resolveDirectory(bookmark: bookmark) else { return false }
            return Self.resolvedPath(url) != path
        }
        defaults.set(kept, forKey: userDirectoryBookmarksKey)
    }

    /// Adds `url` to the exclusion list. Returns `false` if it was already excluded.
    @discardableResult
    public static func addExclusion(_ url: URL, to defaults: UserDefaults = .standard) -> Bool {
        let path = url.standardizedFileURL.path
        var paths = exclusionPaths(from: defaults)
        guard !paths.contains(path) else { return false }
        paths.append(path)
        defaults.set(paths, forKey: exclusionPathsKey)
        return true
    }

    public static func removeExclusion(path: String, from defaults: UserDefaults = .standard) {
        defaults.set(exclusionPaths(from: defaults).filter { $0 != path }, forKey: exclusionPathsKey)
    }

    public static func setRecursionDepth(_ depth: Int, in defaults: UserDefaults = .standard) {
        defaults.set(ScanConfiguration.clamp(depth), forKey: recursionDepthKey)
    }

    // MARK: - Bookmark plumbing

    private static func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) -> Data? {
        if let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        // A build without the user-selected entitlement can reject a security-scoped
        // bookmark; fall back to a plain bookmark so adding a directory never silently fails.
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark created with either option set: try the security-scoped
    /// interpretation first, then a plain resolution, so both persisted kinds round-trip.
    private static func resolveDirectory(bookmark: Data) -> URL? {
        resolve(bookmark: bookmark, options: .withSecurityScope) ?? resolve(bookmark: bookmark, options: [])
    }

    private static func resolve(bookmark: Data, options: URL.BookmarkResolutionOptions) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// The symlink-resolved, canonical path used to compare directories. Matches the
    /// deduplication rule in `AppScanDirectories`.
    private static func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
