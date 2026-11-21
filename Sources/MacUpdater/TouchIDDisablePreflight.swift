import Darwin
import Foundation
import MacUpdaterCore

/// What the app can see, read-only, before it offers a way to turn Touch ID for sudo on or off:
/// whether the helper would refuse, whether a directory outside root's reach could feed `sudo`
/// settings once Touch ID is off, which later policy file `sudo` would read, and whether the app
/// has proof that what `sudo` reads is root's alone. The helper decides on its own facts; a `sudo`
/// command the user types needs the app's proof first (RC2-6).
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

    /// What `lstat` said about one path.
    enum Lookup<Facts: Equatable & Sendable>: Equatable, Sendable {
        case found(Facts)
        /// `ENOENT`: nothing has the name.
        case missing
        /// Any other failure: the app cannot tell what is there.
        case unknown

        var facts: Facts? {
            if case .found(let facts) = self { return facts }
            return nil
        }
    }

    /// Everything the app looked at, before any decision.
    struct Observation: Equatable, Sendable {
        var policyDirectory: Lookup<PAMPolicyDirectoryFacts>
        var sudoLocal: Lookup<PAMPolicyFileFacts>
        /// `/etc/pam.d/sudo`, the head of the chain: `sudo` reads it first, and it includes `sudo_local`.
        var sudoPolicy: Lookup<PAMPolicyFileFacts>
        /// What the app itself read from `sudo_local` (Z4); `nil` when it read nothing.
        var sudoLocalBytes: Data?
        var localDirectories: [LocalDirectory]
        var existingFallbackPaths: [String]
    }

    /// The refusal the helper's own gates give for the facts the app saw: −4 or −5. An ACL the app
    /// could not read and a path it could not look at are no observation here: the helper reads
    /// them again as root.
    var refusal: TouchIDSudoDisableRefusal?
    /// The nearest local policy directory that exists and that someone other than root can change.
    /// Every existing one counts: whoever can write a parent can rename a safe child away.
    var unsafeLocalDirectory: String?
    /// The first later policy file that exists.
    var fallbackPath: String?
    /// RC2-6: positive evidence that what `sudo` reads first is root's alone, so the card may show a
    /// `sudo` command or the helper's button: `/etc/pam.d` looked at, safe and with no ACL;
    /// `sudo_local` missing, or a regular file root's alone with no ACL; `/etc/pam.d/sudo` there, a
    /// regular file root's alone with no ACL. A fact the app could not establish is no evidence.
    var commandsAreSafe = false
    /// `/etc/pam.d/sudo` is there and the app saw that someone other than root can change it.
    var sudoPolicyIsUnsafe = false
    /// What the helper's own rules make of the bytes the app read from `sudo_local` (E.6); `nil`
    /// when it read nothing. The disable command is offered only for `.remove`.
    var removalPlan: TouchIDSudoDisablePlan?

    /// Everything looked at and safe, with nothing to name.
    static let clear = TouchIDDisablePreflight(refusal: nil, unsafeLocalDirectory: nil, fallbackPath: nil, commandsAreSafe: true)

    /// Nearest first: `sudo` reads `sudo_local` from the first of these that can hold one.
    static let localCandidatePaths = ["/usr/local/etc/pam.d", "/usr/local/etc", "/usr/local"]

    static func evaluate(_ observation: Observation) -> TouchIDDisablePreflight {
        TouchIDDisablePreflight(
            refusal: observedRefusal(policyDirectory: observation.policyDirectory.facts, sudoLocal: observation.sudoLocal.facts),
            unsafeLocalDirectory: observation.localDirectories.first { isChangeableByOthers($0.facts) }?.path,
            fallbackPath: observation.existingFallbackPaths.first,
            commandsAreSafe: provesSafety(observation),
            sudoPolicyIsUnsafe: observation.sudoPolicy.facts.map(isSeenUnsafe) ?? false,
            removalPlan: observation.sudoLocalBytes.map(TouchIDSudoConfigurator.contentsDisablingTouchID(current:)))
    }

    private static func provesSafety(_ observation: Observation) -> Bool {
        guard case .found(let directory) = observation.policyDirectory,
              TouchIDSudoDisabler.refusal(directory: directory) == nil else { return false }
        switch observation.sudoLocal {
        case .found(let file): guard isRootsAlone(file) else { return false }
        case .missing: break
        case .unknown: return false
        }
        guard case .found(let sudo) = observation.sudoPolicy else { return false }
        return isRootsAlone(sudo)
    }

    /// A regular file only root can change, with an ACL read as absent: the helper's file gate, in
    /// which an unreadable ACL fails too. Its size is no question of safety.
    private static func isRootsAlone(_ file: PAMPolicyFileFacts) -> Bool {
        let refusal = TouchIDSudoDisabler.refusal(file: file)
        return refusal == nil || refusal == .tooLarge
    }

    /// What the app saw is wrong, an ACL it could not read aside.
    private static func isSeenUnsafe(_ file: PAMPolicyFileFacts) -> Bool {
        var seen = file
        if seen.accessControl == .unreadable { seen.accessControl = .absent }
        return !isRootsAlone(seen)
    }

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

    private static func isChangeableByOthers(_ facts: LocalDirectory.Facts?) -> Bool {
        guard let facts else { return false }
        return facts.isSymbolicLink || facts.ownerUID != 0 || facts.permissions & 0o022 != 0
    }
}

extension TouchIDDisablePreflight {
    /// The facts as `lstat` and the extended-ACL call report them, never following a link.
    static func live() -> TouchIDDisablePreflight {
        let sudoLocalPath = SystemPaths.pamPolicyDirectory + "/sudo_local"
        let sudoLocal = policyFile(at: sudoLocalPath)
        return evaluate(Observation(
            policyDirectory: policyDirectory(at: SystemPaths.pamPolicyDirectory),
            sudoLocal: sudoLocal,
            sudoPolicy: policyFile(at: SystemPaths.pamPolicyDirectory + "/sudo"),
            sudoLocalBytes: sudoLocal.facts.flatMap { readSudoLocal(atPath: sudoLocalPath, identity: $0.identity) },
            localDirectories: localCandidatePaths.map { path in
                LocalDirectory(path: path, facts: lstatEntry(path).map { localFacts($0.status) })
            },
            existingFallbackPaths: TouchIDSudoDisabler.fallbackPolicyPaths.filter { lstatEntry($0) != nil }))
    }

    /// Z4: the app's own read of `sudo_local`, as the user. It opens the name without following a
    /// link and without waiting on a FIFO, reads only a regular file that is still the one `lstat`
    /// saw, and at most one byte past the helper's limit, so it is bounded on the main actor. `nil`
    /// when anything differs or fails.
    static func readSudoLocal(atPath path: String, identity: PAMFileIdentity) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              fileFacts(status, .absent).identity == identity else { return nil }
        let limit = TouchIDSudoDisabler.maximumSize + 1
        var bytes = [UInt8](repeating: 0, count: limit)
        var count = 0
        while count < limit {
            let read = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress.map { $0 + count }, limit - count)
            }
            if read < 0, errno == EINTR { continue }
            guard read >= 0 else { return nil }
            if read == 0 { break }
            count += read
        }
        return Data(bytes[..<count])
    }

    static func policyDirectory(at path: String) -> Lookup<PAMPolicyDirectoryFacts> {
        lookup(path) { directoryFacts($0, accessControl(ofPath: path)) }
    }

    static func policyFile(at path: String) -> Lookup<PAMPolicyFileFacts> {
        lookup(path) { fileFacts($0, accessControl(ofPath: path)) }
    }

    /// Only `ENOENT` is "missing"; any other failure leaves the app knowing nothing.
    private static func lookup<Facts>(_ path: String, _ facts: (stat) -> Facts) -> Lookup<Facts> {
        var status = stat()
        guard lstat(path, &status) == 0 else { return errno == ENOENT ? .missing : .unknown }
        return .found(facts(status))
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
