import Darwin
import Foundation

/// The mount points currently known to the kernel, read without touching any candidate path.
public protocol MountTableReading: Sendable {
    func mountPoints() -> [String]
}

/// Reads the mount table with `getmntinfo(_, MNT_NOWAIT)`, so no volume is asked for fresh
/// statistics and `statfs` is never called on a candidate path.
public struct LiveMountTable: MountTableReading {
    /// `getmntinfo` hands back a buffer that the C library reuses on the next call.
    private static let lock = NSLock()

    public init() {}

    public func mountPoints() -> [String] {
        Self.lock.withLock {
            var table: UnsafeMutablePointer<statfs>?
            let count = Int(getmntinfo(&table, MNT_NOWAIT))
            guard count > 0, let table else { return [] }
            return (0..<count).map { index in
                withUnsafeBytes(of: table[index].f_mntonname) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
        }
    }
}

/// Refuses TCC-protected locations and every volume other than the startup disk, so the scan
/// never raises a permission prompt or wakes a network share.
///
/// Matching is lexical on the standardised path, by whole components, and ignores case because
/// APFS is case-insensitive by default (`~/documents` opens `~/Documents`). Every root is also
/// refused under `/System/Volumes/Data`, the firmlinked path to the same folders. A path is on
/// an allowed volume only when the longest mount point containing it is `/` or lies under
/// `/System/Volumes/`; an empty mount table therefore refuses everything.
public struct ProtectedLocationGuard: Sendable {
    private static let homeRelativeRoots = [
        "Desktop", "Documents", "Downloads",
        "Library/Mobile Documents", "Library/Containers", "Library/Group Containers",
        "Library/Mail", "Library/Messages", "Library/Safari", "Library/CloudStorage",
    ]
    private static let dataVolume = "/System/Volumes/Data"
    private static let systemVolumes = comparable("/System/Volumes")

    private let comparableRoots: [String]
    private let mounts: MountTableReading

    public init(home: URL, mounts: MountTableReading) {
        let roots = Self.protectedRoots(home: home)
        comparableRoots = (roots + roots.map { Self.dataVolume + $0 }).map(Self.comparable)
        self.mounts = mounts
    }

    public static func protectedRoots(home: URL) -> [String] {
        let homePath = standardizedPath(home)
        let prefix = homePath == "/" ? "" : homePath
        return homeRelativeRoots.map { "\(prefix)/\($0)" } + ["/Volumes"]
    }

    /// Throws `.protectedLocation` when `url` lies inside a protected root or on another volume.
    public func check(_ url: URL) throws {
        let path = Self.standardizedPath(url)
        let candidate = Self.comparable(path)
        let isInsideRoot = comparableRoots.contains { Self.isPath(candidate, within: $0) }
        guard !isInsideRoot, isOnAllowedVolume(candidate) else {
            throw CleanupFileSystemError.protectedLocation(path)
        }
    }

    /// `check`, and also refuses `url` when a protected root or another volume's mount point lies
    /// below it — for operations that act on a whole directory tree.
    func checkSubtree(_ url: URL) throws {
        try check(url)
        let path = Self.standardizedPath(url)
        let directory = Self.comparable(path)
        let foreignMounts = mounts.mountPoints().map(Self.comparable).filter { !Self.isAllowedMountPoint($0) }
        guard !(comparableRoots + foreignMounts).contains(where: { Self.isPath($0, within: directory) }) else {
            throw CleanupFileSystemError.protectedLocation(path)
        }
    }

    /// `url.path` with `.` and `..` removed lexically. `URL.standardizedFileURL` is not used: it
    /// drops a leading `/private` only when the shorter path exists, which is a file-system lookup.
    static func standardizedPath(_ url: URL) -> String {
        lexicallyStandardized(url.path)
    }

    private func isOnAllowedVolume(_ candidate: String) -> Bool {
        let mountPoint = mounts.mountPoints()
            .map(Self.comparable)
            .filter { Self.isPath(candidate, within: $0) }
            .max { $0.count < $1.count }
        guard let mountPoint else { return false }
        return Self.isAllowedMountPoint(mountPoint)
    }

    private static func isAllowedMountPoint(_ mountPoint: String) -> Bool {
        mountPoint == "/" || mountPoint.hasPrefix(systemVolumes + "/")
    }

    private static func isPath(_ path: String, within root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    private static func comparable(_ path: String) -> String {
        lexicallyStandardized(path).lowercased()
    }

    private static func lexicallyStandardized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
