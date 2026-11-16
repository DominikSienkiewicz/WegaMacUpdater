import Darwin
import Foundation

/// The filesystem side of staging a root-owned application for the caller's Trash.
///
/// The root helper calls these in the order `UninstallStaging` describes; the decisions between
/// them stay in the pure gates. They live here rather than in the daemon so that a test target
/// compiles them and exercises them: every one also works unprivileged on paths the caller owns.
///
/// Every path is opened or moved with no symbolic link allowed in *any* component
/// (`O_NOFOLLOW_ANY`, `RENAME_NOFOLLOW_ANY`), and every ownership change goes through a
/// descriptor whose device/inode was checked first, never through a name that could be
/// exchanged between the check and the change.
extension UninstallStaging {

    /// A staging slot this helper created: root's alone until `handOverSlot` gives it away.
    public struct Slot: Equatable, Sendable {
        public let path: String
        /// Device/inode of the directory as created, so a replaced slot is never handed over.
        public let identity: PackageStaging.ArtifactIdentity
    }

    /// What the helper read about the entry at the requested path, without following it.
    public struct TargetInspection: Equatable, Sendable {
        /// `lstat` before anything else was read: the inode every later fact must describe.
        public var identity: PackageStaging.ArtifactIdentity
        /// The inode seen while the facts were read: the opened directory's when it was not the
        /// one `identity` names, otherwise a second `lstat` taken after reading. A pair different
        /// from `identity` means the entry was exchanged while its facts were being gathered.
        public var identityAfterReading: PackageStaging.ArtifactIdentity
        /// Owner of the entry itself (`lstat`).
        public var ownerUID: UInt32
        /// Whether the entry itself is a symbolic link (`lstat`).
        public var isSymlink: Bool
        /// Where the validated inode really is, read from its descriptor (`F_GETPATH`); `nil`
        /// when it cannot be opened as a directory with no symlink in its path, or when the
        /// directory opened is not the inode `identity` names.
        public var resolvedPath: String?
        /// `CFBundleIdentifier` read through that same descriptor, or `nil` under the same
        /// conditions or when `Info.plist` is unreadable or reached through a link.
        public var bundleID: String?
    }

    /// What happened to each entry of the moved tree.
    public struct HandOverReport: Equatable, Sendable {
        /// Entries now owned by the caller.
        public var handedOver = 0
        /// Non-directories with more than one hard link, left root-owned: one of their other
        /// names may be a file outside the bundle, such as `/private/etc/sudoers`.
        public var hardLinked: [String] = []
        /// Entries that are not a directory, a file or a link (FIFOs, sockets, devices), or that
        /// sit on another volume, left root-owned.
        public var skipped: [String] = []
        /// Entries that could not be verified or changed, left root-owned.
        public var failed: [String] = []

        /// Every entry of the tree now belongs to the caller.
        public var isComplete: Bool { leftWithRoot == 0 }
        /// How many entries stayed root-owned, for whatever reason.
        public var leftWithRoot: Int { hardLinked.count + skipped.count + failed.count }
    }

    /// An application directory held open, so that facts read through it describe this inode
    /// whatever the name it was opened by points at afterwards. Closed when released.
    public final class OpenedBundle {
        /// Device/inode of the opened directory (`fstat`).
        public let identity: PackageStaging.ArtifactIdentity
        fileprivate let descriptor: Int32

        fileprivate init(descriptor: Int32, identity: PackageStaging.ArtifactIdentity) {
            self.descriptor = descriptor
            self.identity = identity
        }

        deinit { close(descriptor) }
    }

    /// The `lstat` device/inode of `path`, or `nil` when it cannot be read.
    public static func identity(atPath path: String) -> PackageStaging.ArtifactIdentity? {
        linkStatus(path).map(identity(of:))
    }

    /// Reads the facts the gate needs about the entry at `path`, all bound to one inode.
    ///
    /// One `lstat` gives the identity, owner and link-ness. The directory is then opened with no
    /// symlink in its path and must be that same inode; its resolved path and identifier are read
    /// through the descriptor, never by name. `/Applications` is admin-writable, so the name can be
    /// swapped for another bundle while the facts are read and swapped back before the move; read
    /// this way, the facts still describe the validated inode. A second `lstat` follows. `nil`
    /// when the entry cannot be `lstat`ed.
    public static func inspectTarget(atPath path: String) -> TargetInspection? {
        guard let before = linkStatus(path) else { return nil }
        let validated = identity(of: before)
        let opened = openBundle(atPath: path)
        let isValidated = opened?.identity == validated
        let resolved = isValidated ? opened.flatMap(resolvedPath(of:)) : nil
        let bundleID = isValidated ? opened.flatMap(bundleIdentifier(of:)) : nil
        guard let after = linkStatus(path) else { return nil }
        let seenWhileReading: PackageStaging.ArtifactIdentity
        if let opened, !isValidated {
            seenWhileReading = opened.identity
        } else {
            seenWhileReading = identity(of: after)
        }
        return TargetInspection(
            identity: validated,
            identityAfterReading: seenWhileReading,
            ownerUID: before.st_uid,
            isSymlink: fileType(before) == S_IFLNK,
            resolvedPath: resolved,
            bundleID: bundleID
        )
    }

    /// Opens the directory at `path` with no symlink allowed in any component, the last one
    /// included. `nil` when it is not such a directory.
    public static func openBundle(atPath path: String) -> OpenedBundle? {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            return nil
        }
        return OpenedBundle(descriptor: descriptor, identity: identity(of: status))
    }

    /// Where the opened directory is now (`F_GETPATH`), as the kernel names it — the firmlinked
    /// `/Applications/...` form, the same answer `realpath` gives for a path nobody swapped.
    public static func resolvedPath(of bundle: OpenedBundle) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return fcntl(bundle.descriptor, F_GETPATH, base)
        }
        guard result != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { characters in
            characters.baseAddress.map { String(cString: $0) }
        }
    }

    /// `CFBundleIdentifier` from `Contents/Info.plist` inside the opened directory, opened
    /// relative to its descriptor with no symlink allowed, so neither a swapped name nor a linked
    /// `Contents` can lend the bundle another identity.
    ///
    /// Non-blocking, so a FIFO named `Info.plist` cannot stall the helper, and bounded, so a
    /// huge file cannot exhaust it: the bundle is not yet known to be root's when this runs.
    public static func bundleIdentifier(of bundle: OpenedBundle) -> String? {
        let descriptor = openat(bundle.descriptor, "Contents/Info.plist", O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              fileType(status) == S_IFREG,
              status.st_size <= maximumInfoPlistSize,
              let data = try? handle.read(upToCount: Int(maximumInfoPlistSize)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary["CFBundleIdentifier"] as? String
    }

    /// Creates the support directory above `root` and `root` itself when missing, then checks
    /// both as they are now, on every call. `nil` means `root` is safe to stage into.
    ///
    /// The support directory must belong to `ownerUID` and grant nobody else write. It may
    /// predate this verb: `PackageStaging` creates it `0700`, which would keep every caller out
    /// of its own slot, so search for group and other is added when missing, never write.
    public static func prepareRoot(at root: String, ownerUID: UInt32) -> BundleStagingRejection? {
        let support = URL(fileURLWithPath: root).deletingLastPathComponent().path
        guard makeDirectory(support, permissions: 0o711),
              let supportStatus = linkStatus(support),
              fileType(supportStatus) == S_IFDIR,
              supportStatus.st_uid == ownerUID,
              supportStatus.st_mode & 0o022 == 0,
              allowSearch(support, status: supportStatus),
              makeDirectory(root, permissions: 0o711),
              let rootStatus = linkStatus(root) else {
            return .stagingRootUnsafe
        }
        return rootRejection(
            ownerUID: rootStatus.st_uid,
            requiredOwnerUID: ownerUID,
            permissions: rootStatus.st_mode & 0o7777,
            isDirectory: fileType(rootStatus) == S_IFDIR
        )
    }

    /// A fresh `<uuid>/` directory in `root`, mode `0700`, owned by whoever runs this — root, in
    /// the helper. `nil` when it cannot be created as such.
    public static func createSlot(in root: String) -> Slot? {
        let path = root + "/" + UUID().uuidString
        guard mkdir(path, 0o700) == 0 else { return nil }
        guard setPermissions(path, 0o700), let status = linkStatus(path), fileType(status) == S_IFDIR else {
            rmdir(path)
            return nil
        }
        return Slot(path: path, identity: identity(of: status))
    }

    /// Removes `slot` if it is still empty; used when nothing was moved into it.
    @discardableResult
    public static func discardSlot(_ slot: Slot) -> Bool {
        rmdir(slot.path) == 0
    }

    /// Removes every empty `<uuid>/` slot left in `root`, typically after the app moved a staged
    /// bundle on to the Trash. `rmdir` removes only empty directories and never follows a link,
    /// so a non-empty slot, a file or a link is left alone. Returns how many were removed.
    @discardableResult
    public static func sweepEmptySlots(in root: String) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return 0 }
        var removed = 0
        for name in names where UUID(uuidString: name)?.uuidString == name {
            if rmdir(root + "/" + name) == 0 { removed += 1 }
        }
        return removed
    }

    /// Moves `source` into `slot` with one `rename(2)` and returns the staged path. A symbolic
    /// link in any component of either path fails the move instead of redirecting it, and an
    /// existing destination is never replaced.
    public static func renameIntoSlot(_ source: String, slot: Slot) throws -> String {
        guard let name = source.utf8.split(separator: UInt8(ascii: "/")).last.map({ String(decoding: $0, as: UTF8.self) }),
              name != ".", name != ".." else {
            throw POSIXError(.EINVAL)
        }
        let destination = slot.path + "/" + name
        guard renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_NOFOLLOW_ANY | RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destination
    }

    /// Gives every entry of the tree at `path` to `uid`/`gid`, children before their directory.
    ///
    /// A physical walk (`FTS_PHYSICAL`) that never leaves the volume (`FTS_XDEV`) and never
    /// changes the process's working directory (`FTS_NOCHDIR`), since the helper serves other
    /// connections concurrently. The walk starts only if its root is `expected`. Each entry is
    /// then opened with no symlink allowed in its path (a link itself is opened as a link), and
    /// the descriptor must be the device/inode the walk saw, on the bundle's volume, and, unless
    /// it is a directory, carry a single hard link (`st_nlink`) before `fchown` changes it. So a
    /// name exchanged mid-walk changes nothing, and no file with a name outside the tree is
    /// ever given away.
    public static func handOverTree(
        at path: String, expected: PackageStaging.ArtifactIdentity, toUID uid: uid_t, gid: gid_t
    ) -> HandOverReport {
        var report = HandOverReport()
        guard let rootPath = strdup(path) else {
            report.failed.append(path)
            return report
        }
        defer { free(rootPath) }
        let arguments: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        guard let walk = arguments.withUnsafeBufferPointer({
            fts_open($0.baseAddress, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil)
        }) else {
            report.failed.append(path)
            return report
        }
        defer { fts_close(walk) }

        while let entry = fts_read(walk) {
            let entryPath = String(cString: entry.pointee.fts_path)
            guard let walked = entry.pointee.fts_statp?.pointee else {
                report.failed.append(entryPath)
                continue
            }
            let info = Int32(entry.pointee.fts_info)
            if entry.pointee.fts_level == 0, info != FTS_DP {
                guard info == FTS_D, identity(of: walked) == expected else {
                    report.failed.append(entryPath)
                    return report
                }
            }
            switch info {
            case FTS_D:
                if identity(of: walked).device != expected.device {
                    report.skipped.append(entryPath)
                    fts_set(walk, entry, FTS_SKIP)
                }
            case FTS_DP:
                // fts also reports a skipped or other-volume directory here; preorder recorded it.
                guard identity(of: walked).device == expected.device else { continue }
                record(changeOwner(entry.pointee.fts_accpath, walked: walked, expected: expected, uid: uid, gid: gid),
                       for: entryPath, in: &report)
            case FTS_F, FTS_SL, FTS_SLNONE:
                guard walked.st_nlink == 1 else {
                    report.hardLinked.append(entryPath)
                    continue
                }
                record(changeOwner(entry.pointee.fts_accpath, walked: walked, expected: expected, uid: uid, gid: gid),
                       for: entryPath, in: &report)
            case FTS_DEFAULT, FTS_DC:
                report.skipped.append(entryPath)
            default:
                report.failed.append(entryPath)
            }
        }
        return report
    }

    /// Gives `slot` itself to `uid`/`gid`, mode unchanged (`0700`), but only while it is still
    /// the directory `createSlot` made.
    public static func handOverSlot(_ slot: Slot, toUID uid: uid_t, gid: gid_t) -> Bool {
        let descriptor = open(slot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, identity(of: status) == slot.identity else { return false }
        return fchown(descriptor, uid, gid) == 0
    }

    // MARK: - Private

    private enum OwnerChange {
        case handedOver
        case hardLinked
        case failed
    }

    private static let maximumInfoPlistSize: off_t = 4 << 20

    private static func record(_ change: OwnerChange, for path: String, in report: inout HandOverReport) {
        switch change {
        case .handedOver: report.handedOver += 1
        case .hardLinked: report.hardLinked.append(path)
        case .failed: report.failed.append(path)
        }
    }

    /// Opens the walked entry by its path with no symlink allowed in any component (`O_SYMLINK`
    /// opens a link itself rather than its target) and changes the owner through that
    /// descriptor, once it is proven to be the entry the walk saw.
    private static func changeOwner(
        _ path: UnsafePointer<CChar>, walked: stat, expected: PackageStaging.ArtifactIdentity, uid: uid_t, gid: gid_t
    ) -> OwnerChange {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failed }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              identity(of: opened) == identity(of: walked),
              identity(of: opened).device == expected.device,
              fileType(opened) == fileType(walked) else {
            return .failed
        }
        guard fileType(opened) == S_IFDIR || opened.st_nlink == 1 else { return .hardLinked }
        return fchown(descriptor, uid, gid) == 0 ? .handedOver : .failed
    }

    private static func linkStatus(_ path: String) -> stat? {
        var status = stat()
        return lstat(path, &status) == 0 ? status : nil
    }

    private static func identity(of status: stat) -> PackageStaging.ArtifactIdentity {
        PackageStaging.ArtifactIdentity(
            device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino)
        )
    }

    private static func fileType(_ status: stat) -> mode_t {
        status.st_mode & S_IFMT
    }

    /// `mkdir` with exactly `permissions` when it creates the directory, whatever the umask;
    /// an existing entry is left as it is for the caller to check.
    private static func makeDirectory(_ path: String, permissions: mode_t) -> Bool {
        if mkdir(path, permissions) == 0 { return setPermissions(path, permissions) }
        return errno == EEXIST
    }

    private static func setPermissions(_ path: String, _ permissions: mode_t) -> Bool {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fchmod(descriptor, permissions) == 0
    }

    /// Adds search for group and other to a directory that lacks it, through a descriptor proven
    /// to be the directory that was checked.
    private static func allowSearch(_ path: String, status: stat) -> Bool {
        guard status.st_mode & 0o011 != 0o011 else { return true }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, identity(of: opened) == identity(of: status) else { return false }
        return fchmod(descriptor, (opened.st_mode & 0o7777) | 0o011) == 0
    }
}
