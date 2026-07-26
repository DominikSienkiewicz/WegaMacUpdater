import Foundation

/// SEC-03: the rules that make `installVerifiedPackage` verify and install *the same bytes*.
///
/// The helper used to check the signature of a file at a path the client chose, and then hand
/// that same path to `installer`. The path pointed into a directory writable by user processes,
/// so anything could be swapped in between the two reads — a local escalation to root that
/// needed no exploit, only timing.
///
/// The fix has two halves. The helper copies the input into a directory it owns and installs
/// from there, and it re-checks that the file it is about to install is byte-identical in
/// identity (same device, same inode) to the one it verified. Neither half is enough alone:
/// staging without the identity re-check still leaves a window, and the identity check on a
/// user-writable path only proves the attacker did not bother to race.
///
/// Everything here is a pure decision over facts the daemon supplies. `WegaPrivilegedHelper`
/// runs only as root and no test target can reach it — which is exactly how the sibling `..`
/// traversal in `replaceBundle` survived unnoticed until an audit found it by reading code.
public enum PackageStaging {

    /// Why the helper refuses to install a staged artifact.
    public enum Rejection: Equatable, Sendable {
        /// The staging directory is not owned by root — a user could still swap its contents.
        case notOwnedByRoot
        /// The staging directory grants access beyond its owner.
        case permissionsTooOpen
        /// The artifact about to be installed is not the one that was verified.
        case identityChanged
        /// The install path does not resolve inside this bundle's staging directory.
        case outsideStaging
    }

    /// The filesystem identity of an artifact: `st_dev` + `st_ino`.
    ///
    /// The pair, never the inode alone — inode numbers are only unique within a volume, so two
    /// different files on two volumes can share one.
    public struct ArtifactIdentity: Equatable, Sendable {
        public var device: UInt64
        public var inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    /// Root-owned staging for `bundleID`, on the system volume so that a later move into
    /// `/Applications` stays on one filesystem.
    public static func directory(bundleID: String) -> URL {
        URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
    }

    /// The staging directory must be owned by root and reachable by nobody else.
    ///
    /// Stricter than `0700` is fine; anything granting group or other access is not, because
    /// the whole point of the directory is that the attacker cannot write into it.
    public static func rejection(ownerUID: UInt32, permissions: UInt16) -> Rejection? {
        guard ownerUID == 0 else { return .notOwnedByRoot }
        guard permissions & 0o077 == 0 else { return .permissionsTooOpen }
        return nil
    }

    /// The artifact verified and the artifact installed must be the same file.
    public static func rejection(
        verified: ArtifactIdentity,
        installing: ArtifactIdentity
    ) -> Rejection? {
        verified == installing ? nil : .identityChanged
    }

    /// The path handed to `installer` must resolve inside this bundle's staging directory.
    ///
    /// Canonicalised and compared component-wise, for the reason part 1 of SEC-03 established:
    /// a prefix test on a raw string accepts both `..` traversals and lookalike directories.
    public static func rejectionForInstallPath(_ path: String, bundleID: String) -> Rejection? {
        guard path.hasPrefix("/") else { return .outsideStaging }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        let expected = directory(bundleID: bundleID).standardizedFileURL.pathComponents
        let actual = standardized.pathComponents
        guard actual.count > expected.count,
              Array(actual.prefix(expected.count)) == expected else {
            return .outsideStaging
        }
        return nil
    }
}
