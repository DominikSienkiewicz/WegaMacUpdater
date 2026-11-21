import Darwin
import Foundation
import MacUpdaterCore

/// What the app can see, read-only, before it offers to turn Touch ID for sudo off: whether the
/// helper would refuse, whether a directory outside root's reach could feed `sudo` settings once
/// Touch ID is off, and which later policy file `sudo` would read. The helper decides on its own
/// facts; the app only hides the button for a condition it actually observed.
struct TouchIDDisablePreflight: Equatable, Sendable {
    struct LocalDirectory: Equatable, Sendable {
        struct Facts: Equatable, Sendable {
            var isSymbolicLink: Bool
            var ownerUID: UInt32
            var permissions: UInt16
        }

        var path: String
        var facts: Facts?
    }

    /// The refusal the helper's own gates give for the facts the app saw: −4 or −5.
    var refusal: TouchIDSudoDisableRefusal?
    /// The nearest existing local policy directory that someone other than root can change.
    var unsafeLocalDirectory: String?
    /// The first later policy file that exists.
    var fallbackPath: String?

    static let clear = TouchIDDisablePreflight(refusal: nil, unsafeLocalDirectory: nil, fallbackPath: nil)

    /// Nearest first: `sudo` reads `sudo_local` from the first of these that can hold one.
    static let localCandidatePaths = ["/usr/local/etc/pam.d", "/usr/local/etc", "/usr/local"]

    static func evaluate(
        policyDirectory: PAMPolicyDirectoryFacts?, sudoLocal: PAMPolicyFileFacts?,
        localDirectories: [LocalDirectory], existingFallbackPaths: [String]
    ) -> TouchIDDisablePreflight {
        TouchIDDisablePreflight(
            refusal: observedRefusal(policyDirectory: policyDirectory, sudoLocal: sudoLocal),
            unsafeLocalDirectory: nearestExisting(localDirectories).flatMap { isChangeableByOthers($0.facts) ? $0.path : nil },
            fallbackPath: existingFallbackPaths.first)
    }

    /// An ACL the app could not read is not an observation: the helper reads it again as root.
    private static func observedRefusal(
        policyDirectory: PAMPolicyDirectoryFacts?, sudoLocal: PAMPolicyFileFacts?
    ) -> TouchIDSudoDisableRefusal? {
        if var directory = policyDirectory {
            if directory.accessControl == .unreadable { directory.accessControl = .absent }
            if let refusal = TouchIDSudoDisabler.refusal(directory: directory) { return refusal }
        }
        if var file = sudoLocal {
            if file.accessControl == .unreadable { file.accessControl = .absent }
            if let refusal = TouchIDSudoDisabler.refusal(file: file), refusal != .tooLarge { return refusal }
        }
        return nil
    }

    private static func nearestExisting(_ directories: [LocalDirectory]) -> LocalDirectory? {
        directories.first { $0.facts != nil }
    }

    private static func isChangeableByOthers(_ facts: LocalDirectory.Facts?) -> Bool {
        guard let facts else { return false }
        return facts.isSymbolicLink || facts.ownerUID != 0 || facts.permissions & 0o022 != 0
    }
}

extension TouchIDDisablePreflight {
    /// The facts as `lstat` and the extended-ACL call report them, never following a link.
    static func live() -> TouchIDDisablePreflight {
        evaluate(
            policyDirectory: lstatEntry(SystemPaths.pamPolicyDirectory).map { directoryFacts($0.status, $0.acl) },
            sudoLocal: lstatEntry(SystemPaths.pamPolicyDirectory + "/sudo_local").map { fileFacts($0.status, $0.acl) },
            localDirectories: localCandidatePaths.map { path in
                LocalDirectory(path: path, facts: lstatEntry(path).map { localFacts($0.status) })
            },
            existingFallbackPaths: TouchIDSudoDisabler.fallbackPolicyPaths.filter { lstatEntry($0) != nil })
    }

    private static func lstatEntry(_ path: String) -> (status: stat, acl: PAMAccessControlState)? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return (status, accessControl(ofPath: path))
    }

    private static func accessControl(ofPath path: String) -> PAMAccessControlState {
        guard let list = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? .absent : .unreadable
        }
        acl_free(UnsafeMutableRawPointer(list))
        return .present
    }

    private static func directoryFacts(_ status: stat, _ acl: PAMAccessControlState) -> PAMPolicyDirectoryFacts {
        PAMPolicyDirectoryFacts(
            isDirectory: status.st_mode & S_IFMT == S_IFDIR, ownerUID: status.st_uid,
            permissions: UInt16(status.st_mode & 0o7777), accessControl: acl)
    }

    private static func fileFacts(_ status: stat, _ acl: PAMAccessControlState) -> PAMPolicyFileFacts {
        PAMPolicyFileFacts(
            isRegularFile: status.st_mode & S_IFMT == S_IFREG,
            identity: PAMFileIdentity(device: UInt64(bitPattern: Int64(status.st_dev)), inode: status.st_ino),
            linkCount: UInt32(status.st_nlink), ownerUID: status.st_uid, groupID: status.st_gid,
            permissions: UInt16(status.st_mode & 0o7777), accessControl: acl, size: status.st_size, modifiedNanoseconds: 0)
    }

    private static func localFacts(_ status: stat) -> LocalDirectory.Facts {
        LocalDirectory.Facts(
            isSymbolicLink: status.st_mode & S_IFMT == S_IFLNK, ownerUID: status.st_uid,
            permissions: UInt16(status.st_mode & 0o7777))
    }
}
