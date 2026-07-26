import Foundation

/// User-tunable inputs to `AppScanDirectories` (UX-16): extra roots the user added, folders
/// to skip, and how many sub-levels to descend below every root.
///
/// This is the *resolved* value handed to the scan; persistence (bookmarks, `UserDefaults`)
/// lives in `ScanConfigurationStore`. The default value reproduces the historical behaviour
/// exactly — the built-in roots plus their immediate children (`recursionDepth == 1`), no
/// user directories, no exclusions — so an app that never touches Settings scans as before.
public struct ScanConfiguration: Equatable, Sendable {
    /// One sub-level below each root — `/Applications` plus `/Applications/JetBrains/`, etc.
    public static let defaultRecursionDepth = 1
    /// A ceiling so a misconfigured depth can't turn a scan into a full-disk walk.
    public static let maximumRecursionDepth = 8

    /// Extra roots to scan on top of `/Applications` and `~/Applications` — other volumes,
    /// non-standard install locations. Already resolved to concrete directory URLs.
    public var userDirectories: [URL]
    /// Directories that must never be scanned. Matched against a candidate and its subtree
    /// by resolved path, so excluding a parent prunes everything beneath it.
    public var exclusions: [URL]
    /// How many directory levels below each root to descend. `0` = the root only.
    public var recursionDepth: Int

    public init(
        userDirectories: [URL] = [],
        exclusions: [URL] = [],
        recursionDepth: Int = ScanConfiguration.defaultRecursionDepth
    ) {
        self.userDirectories = userDirectories
        self.exclusions = exclusions
        self.recursionDepth = ScanConfiguration.clamp(recursionDepth)
    }

    public static func clamp(_ depth: Int) -> Int {
        min(max(depth, 0), maximumRecursionDepth)
    }
}
