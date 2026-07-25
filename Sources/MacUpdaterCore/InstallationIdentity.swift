import Foundation

/// REL-16 — what makes one installed copy of an application *that* copy.
///
/// The identity is the standardized on-disk path of the bundle. A bundle
/// identifier is not an identity: two copies of Firefox — one in `/Applications`,
/// one in `~/Applications` — share it, and treating them as one entry hid the
/// second copy from the inventory and let a destructive operation act on a copy
/// the user never saw.
///
/// Standardization is deliberately **pure**: it never touches the filesystem.
/// An identity that changed when the bundle it names disappeared would betray a
/// selection at exactly the wrong moment — uninstall rescans right after
/// trashing an app, and the surviving rows must keep the identities they had.
/// The rules are:
///
/// * `~` is expanded, `.` and `..` components are resolved, a trailing slash is
///   dropped (`URL.standardizedFileURL`);
/// * a leading `/private` in front of `/tmp`, `/var` or `/etc` is dropped, so the
///   two spellings of the same file — macOS resolves those three roots into
///   `/private` — do not become two installations;
/// * the path is normalized to NFC. APFS and HFS+ compare filenames
///   normalization-insensitively, so two spellings that differ only in Unicode
///   composition are the same file on disk and must be the same identity;
/// * case is **preserved**. Case-folding would be right on the default
///   case-insensitive APFS volume and wrong on a case-sensitive one, where
///   `/Applications/App.app` and `/Applications/app.app` are two different
///   bundles. Merging two distinct installations is the failure this whole card
///   is about, so the direction that can only ever split — never merge — wins.
///   Paths come from directory enumeration, which reports the on-disk spelling,
///   so the split case does not arise in practice.
public struct InstallationIdentity: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(path: URL) {
        self.init(path: path.path)
    }

    public init(path: String) {
        rawValue = Self.standardize(path)
    }

    public var description: String { rawValue }

    public static func < (lhs: InstallationIdentity, rhs: InstallationIdentity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The three root directories macOS symlinks into `/private`.
    private static let privateRoots = ["/tmp", "/var", "/etc"]

    private static func standardize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL.path
        return stripPrivatePrefix(standardized).precomposedStringWithCanonicalMapping
    }

    private static func stripPrivatePrefix(_ path: String) -> String {
        for root in privateRoots where path == "/private" + root || path.hasPrefix("/private" + root + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}

public extension ApplicationInfo {
    /// The installed copy this record describes — see `InstallationIdentity`.
    var installation: InstallationIdentity { InstallationIdentity(path: path) }

    /// The folder this copy lives in, written the way the user would write it.
    /// Shown next to the name when one bundle identifier has more than one
    /// installation, so the row the user ticks is the row they meant.
    var locationLabel: String {
        (path.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
