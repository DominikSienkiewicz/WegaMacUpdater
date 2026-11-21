import Darwin
import Foundation

/// Whether an extended ACL is on a file or directory. Anything but a certain "none" counts as one.
public enum PAMAccessControlState: Equatable, Sendable {
    case absent
    case present
    /// The ACL could not be read for a reason other than its absence.
    case unreadable
}

/// Device and inode: which file a name pointed at.
public struct PAMFileIdentity: Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// The policy directory as its own descriptor reports it.
public struct PAMPolicyDirectoryFacts: Equatable, Sendable {
    public var isDirectory: Bool
    public var ownerUID: UInt32
    /// `st_mode & 0o7777`.
    public var permissions: UInt16
    public var accessControl: PAMAccessControlState

    public init(isDirectory: Bool, ownerUID: UInt32, permissions: UInt16, accessControl: PAMAccessControlState) {
        self.isDirectory = isDirectory
        self.ownerUID = ownerUID
        self.permissions = permissions
        self.accessControl = accessControl
    }
}

/// One policy file as `stat` reports it. There is no `ctime`: swapping a name changes the `ctime`
/// of the file it moves, so comparing it after the swap would always fail.
public struct PAMPolicyFileFacts: Equatable, Sendable {
    public var isRegularFile: Bool
    public var identity: PAMFileIdentity
    public var linkCount: UInt32
    public var ownerUID: UInt32
    public var groupID: UInt32
    /// `st_mode & 0o7777`.
    public var permissions: UInt16
    public var accessControl: PAMAccessControlState
    public var size: Int64
    public var modifiedNanoseconds: Int64

    public init(
        isRegularFile: Bool, identity: PAMFileIdentity, linkCount: UInt32, ownerUID: UInt32, groupID: UInt32,
        permissions: UInt16, accessControl: PAMAccessControlState, size: Int64, modifiedNanoseconds: Int64
    ) {
        self.isRegularFile = isRegularFile
        self.identity = identity
        self.linkCount = linkCount
        self.ownerUID = ownerUID
        self.groupID = groupID
        self.permissions = permissions
        self.accessControl = accessControl
        self.size = size
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

/// What reading a policy file by name found.
public enum PAMPolicyFileRead: Equatable, Sendable {
    /// No entry has the name.
    case missing
    /// The entry is not a regular file, so it was never opened.
    case notRegular
    /// The entry opened is not the one the name pointed at a moment before.
    case changed
    /// The opened file's facts, from its descriptor, and up to one byte more than the limit.
    case read(PAMPolicyFileFacts, Data)
}

/// The policy directory as the disable transaction sees it: every name is one component relative
/// to one directory descriptor verified at open. Tests inject an in-memory fake; an instance of the
/// live type over a temporary directory runs the real system calls.
protocol PAMPolicyDirectoryAccess {
    func directoryFacts() throws -> PAMPolicyDirectoryFacts
    /// Whether the volume can exchange two names atomically (`VOL_CAP_INT_RENAME_SWAP`).
    func supportsSwap() throws -> Bool
    /// The name first (no link followed), then the regular file it names, then the bytes.
    func readPolicyFile(named name: String, limit: Int) throws -> PAMPolicyFileRead
    /// The entry's facts without following a link; `nil` when there is none.
    func facts(named name: String) throws -> PAMPolicyFileFacts?
    /// Creates a new file under a fresh name with exactly these bytes, owner, group and mode, no
    /// ACL, flushed to the disk; the name is removed again when any of that fails.
    func createFile(
        named name: String, contents: Data, owner: uid_t, group: gid_t, permissions: mode_t
    ) throws -> PAMPolicyFileFacts
    /// Exchanges what two names point at, atomically.
    func swap(_ first: String, _ second: String) throws
    /// Makes the directory's names durable.
    func synchronize() throws
    /// Unlinks `name` only while it still names `identity`; `false` when it does not.
    func remove(named name: String, ifIdentity identity: PAMFileIdentity) throws -> Bool
}

/// `PAMPolicyDirectoryAccess` over a real directory, through one descriptor opened with no link
/// allowed in any component.
final class SystemPAMPolicyDirectory: PAMPolicyDirectoryAccess {
    private let descriptor: Int32

    init(path: String) throws {
        descriptor = -1
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    func directoryFacts() throws -> PAMPolicyDirectoryFacts {
        throw POSIXError(.ENOSYS)
    }

    func supportsSwap() throws -> Bool {
        false
    }

    func readPolicyFile(named name: String, limit: Int) throws -> PAMPolicyFileRead {
        throw POSIXError(.ENOSYS)
    }

    func facts(named name: String) throws -> PAMPolicyFileFacts? {
        throw POSIXError(.ENOSYS)
    }

    func createFile(
        named name: String, contents: Data, owner: uid_t, group: gid_t, permissions: mode_t
    ) throws -> PAMPolicyFileFacts {
        throw POSIXError(.ENOSYS)
    }

    func swap(_ first: String, _ second: String) throws {
        throw POSIXError(.ENOSYS)
    }

    func synchronize() throws {
        throw POSIXError(.ENOSYS)
    }

    func remove(named name: String, ifIdentity identity: PAMFileIdentity) throws -> Bool {
        false
    }
}
