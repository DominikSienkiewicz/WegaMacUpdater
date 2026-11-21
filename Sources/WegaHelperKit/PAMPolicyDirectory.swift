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
/// allowed in any component. Every name is a single component relative to that descriptor.
final class SystemPAMPolicyDirectory: PAMPolicyDirectoryAccess {
    private let descriptor: Int32

    init(path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.lastError() }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    func directoryFacts() throws -> PAMPolicyDirectoryFacts {
        let status = try Self.status(of: descriptor)
        return PAMPolicyDirectoryFacts(
            isDirectory: Self.fileType(status) == S_IFDIR, ownerUID: status.st_uid,
            permissions: UInt16(status.st_mode & 0o7777), accessControl: Self.accessControl(of: descriptor)
        )
    }

    /// `fgetattrlist(ATTR_VOL_CAPABILITIES)`: the reply is its length, then the capability set and
    /// the valid set, four words each, indexed by `VOL_CAPABILITIES_INTERFACES`.
    func supportsSwap() throws -> Bool {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        var reply = [UInt32](repeating: 0, count: 9)
        let result = reply.withUnsafeMutableBytes { buffer in
            fgetattrlist(descriptor, &request, buffer.baseAddress, buffer.count, 0)
        }
        guard result == 0 else { throw Self.lastError() }
        guard reply[0] >= UInt32(MemoryLayout<UInt32>.size * reply.count) else { return false }
        let interfaces = Int(VOL_CAPABILITIES_INTERFACES)
        let swap = UInt32(VOL_CAP_INT_RENAME_SWAP)
        return reply[1 + interfaces] & swap != 0 && reply[5 + interfaces] & swap != 0
    }

    func readPolicyFile(named name: String, limit: Int) throws -> PAMPolicyFileRead {
        guard let named = try entryStatus(name) else { return .missing }
        guard Self.fileType(named) == S_IFREG else { return .notRegular }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT || errno == ELOOP { return .changed }
            throw Self.lastError()
        }
        defer { close(file) }
        let opened = try Self.status(of: file)
        guard Self.fileType(opened) == S_IFREG, Self.identity(of: opened) == Self.identity(of: named) else {
            return .changed
        }
        let facts = Self.fileFacts(opened, accessControl: Self.accessControl(of: file))
        return .read(facts, try Self.readAll(file, upTo: limit + 1))
    }

    func facts(named name: String) throws -> PAMPolicyFileFacts? {
        guard let status = try entryStatus(name) else { return nil }
        return Self.fileFacts(status, accessControl: accessControl(ofEntry: name, status: status))
    }

    /// `O_CREAT | O_EXCL | O_NOFOLLOW` at `0600`, so the name is new and never a link; then the
    /// bytes, `fchown`, `fchmod` (after `fchown`, which may clear set-id bits), the ACL check and a
    /// full flush, all on the descriptor.
    func createFile(
        named name: String, contents: Data, owner: uid_t, group: gid_t, permissions: mode_t
    ) throws -> PAMPolicyFileFacts {
        let file = openat(descriptor, try Self.single(name), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.lastError() }
        defer { close(file) }
        let created = Self.identity(of: try Self.status(of: file))
        do {
            try Self.writeAll(contents, to: file)
            guard fchown(file, owner, group) == 0, fchmod(file, permissions) == 0 else { throw Self.lastError() }
            guard Self.accessControl(of: file) == .absent else { throw POSIXError(.EPERM) }
            try Self.flush(file)
            return Self.fileFacts(try Self.status(of: file), accessControl: .absent)
        } catch {
            _ = try? remove(named: name, ifIdentity: created)
            throw error
        }
    }

    func swap(_ first: String, _ second: String) throws {
        guard renameatx_np(descriptor, try Self.single(first), descriptor, try Self.single(second), UInt32(RENAME_SWAP)) == 0 else {
            throw Self.lastError()
        }
    }

    func synchronize() throws {
        try Self.flush(descriptor)
    }

    func remove(named name: String, ifIdentity identity: PAMFileIdentity) throws -> Bool {
        guard let status = try entryStatus(name), Self.identity(of: status) == identity else { return false }
        guard unlinkat(descriptor, name, 0) == 0 else { throw Self.lastError() }
        return true
    }

    // MARK: - Private

    /// `fstatat` without following a link; `nil` when nothing has the name.
    private func entryStatus(_ name: String) throws -> stat? {
        var status = stat()
        guard fstatat(descriptor, try Self.single(name), &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.lastError()
        }
        return status
    }

    /// The ACL of a regular file, read through a descriptor proven to be the entry `status` saw.
    private func accessControl(ofEntry name: String, status: stat) -> PAMAccessControlState {
        guard Self.fileType(status) == S_IFREG else { return .unreadable }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return .unreadable }
        defer { close(file) }
        guard let opened = try? Self.status(of: file), Self.identity(of: opened) == Self.identity(of: status) else {
            return .unreadable
        }
        return Self.accessControl(of: file)
    }

    /// RC4: only a missing ACL with `ENOENT` is "none"; any other answer refuses.
    static func accessControl(of descriptor: Int32) -> PAMAccessControlState {
        errno = 0
        guard let list = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? .absent : .unreadable
        }
        acl_free(UnsafeMutableRawPointer(list))
        return .present
    }

    /// `F_FULLFSYNC`, falling back to `fsync` only where the file system does not support it.
    private static func flush(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard errno == ENOTSUP || errno == EINVAL else { throw lastError() }
        guard fsync(descriptor) == 0 else { throw lastError() }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw written == 0 ? POSIXError(.EIO) : lastError() }
                offset += written
            }
        }
    }

    private static func readAll(_ descriptor: Int32, upTo limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < limit {
            let wanted = min(buffer.count, limit - data.count)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw lastError() }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// A name is one component: never empty, `.`, `..`, or holding a `/` or a NUL.
    private static func single(_ name: String) throws -> String {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, name != ".", name != "..", !bytes.contains(UInt8(ascii: "/")), !bytes.contains(0) else {
            throw POSIXError(.EINVAL)
        }
        return name
    }

    private static func status(of descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw lastError() }
        return status
    }

    private static func fileFacts(_ status: stat, accessControl: PAMAccessControlState) -> PAMPolicyFileFacts {
        PAMPolicyFileFacts(
            isRegularFile: fileType(status) == S_IFREG, identity: identity(of: status),
            linkCount: UInt32(status.st_nlink), ownerUID: status.st_uid, groupID: status.st_gid,
            permissions: UInt16(status.st_mode & 0o7777), accessControl: accessControl,
            size: Int64(status.st_size),
            // Wrapping: a far-future `mtime` set by root must not trap the daemon; only equality matters.
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private static func identity(of status: stat) -> PAMFileIdentity {
        PAMFileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino))
    }

    private static func fileType(_ status: stat) -> mode_t {
        status.st_mode & S_IFMT
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
