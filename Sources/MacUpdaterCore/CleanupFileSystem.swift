import Darwin
import Foundation

public enum CleanupEntryKind: Sendable {
    case file, directory, symlink, other
}

/// What `lstat` reports about one item; a symlink describes the link, never its target.
public struct CleanupEntry: Equatable, Sendable {
    public let url: URL
    public let kind: CleanupEntryKind
    /// The owner-execute bit of the item itself (`S_IXUSR`).
    public let isExecutable: Bool
    public let identity: CleanupFileIdentity
    public let modificationDate: Date?

    public init(url: URL, kind: CleanupEntryKind, isExecutable: Bool, identity: CleanupFileIdentity, modificationDate: Date?) {
        self.url = url
        self.kind = kind
        self.isExecutable = isExecutable
        self.identity = identity
        self.modificationDate = modificationDate
    }
}

public enum CleanupFileSystemError: Error, Equatable {
    case protectedLocation(String)
    case symlinkLoop(String)
    case notFound(String)
    case io(String)
}

/// The only way Cleanup code reaches the disk. Production wraps `LiveCleanupFileSystem` in
/// `GuardedCleanupFileSystem`; nothing here deletes permanently.
///
/// Build the URLs passed here with `URL(filePath:directoryHint:)` or `appending(path:)`:
/// `URL(fileURLWithPath:)` and `appendingPathComponent(_:)` stat the path to learn whether it
/// is a directory, which is a file-system access the guard cannot see.
public protocol CleanupFileSystem: Sendable {
    /// `lstat` of `url`; nil when nothing is there.
    func entry(at url: URL) throws -> CleanupEntry?
    /// The entries directly inside `directory`, sorted by name.
    func contents(of directory: URL) throws -> [CleanupEntry]
    /// The link's stored destination, verbatim (it may be relative).
    func symlinkDestination(of url: URL) throws -> String
    /// The physical path, resolved component by component like realpath(3); more than 40 links
    /// throw `.symlinkLoop`.
    func realpath(_ url: URL) throws -> URL
    /// Bytes allocated on disk. A symlink counts as the link itself; a directory is summed
    /// without following the links inside it.
    func allocatedSize(of url: URL) throws -> Int64
    /// Raw file contents, up to the stated byte limit.
    func readData(_ url: URL, maxBytes: Int) throws -> Data
    /// UTF-8 contents; throws `.io` instead of truncating a file larger than `maxBytes`.
    func readText(_ url: URL, maxBytes: Int) throws -> String
    /// Creates one directory; its parent must exist.
    func createDirectory(_ url: URL) throws
    func moveItem(_ source: URL, to destination: URL) throws
    /// Moves the item to the Trash.
    func trash(_ url: URL) throws
}

public extension CleanupFileSystem {
    func readData(_ url: URL, maxBytes: Int) throws -> Data {
        Data(try readText(url, maxBytes: maxBytes).utf8)
    }
}

/// Physical path resolution shared by the live adapter and the guarded wrapper. Like realpath(3)
/// it walks component by component, so links in the middle of a path (`/var` → `private/var`)
/// are followed too, and a relative link destination resolves against the link's parent.
/// Paths and link destinations are split on scalars (`CleanupPathText`); a destination holding a
/// NUL is refused before any URL is built from it.
/// `check` sees the input and every resolved candidate before it is lstat-ed or its link read.
struct CleanupPathResolver {
    static let maximumSymlinkHops = 40

    let check: (URL) throws -> Void
    let entry: (URL) throws -> CleanupEntry?
    let destination: (URL) throws -> String

    /// The physical path of `url`, following every link including the last component.
    func resolve(_ url: URL) throws -> URL {
        try walk(url, followingFinalLink: true)
    }

    /// The physical location of the item `url` names, the way `lstat`, `readlink` and `rename`
    /// reach it: every link but the last component is followed, and the item need not exist.
    func locate(_ url: URL) throws -> URL {
        try walk(url, followingFinalLink: false)
    }

    private func walk(_ url: URL, followingFinalLink: Bool) throws -> URL {
        try check(url)
        var pending = CleanupPathText.components(of: url.path)
        var resolved: [String] = []
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                _ = resolved.popLast()
                continue
            }
            let candidate = Self.url(resolved + [component])
            try check(candidate)
            if pending.isEmpty, !followingFinalLink {
                resolved.append(component)
                continue
            }
            guard let found = try entry(candidate) else {
                throw CleanupFileSystemError.notFound(candidate.path)
            }
            guard found.kind == .symlink else {
                guard found.kind == .directory || pending.isEmpty else {
                    throw CleanupFileSystemError.notFound(candidate.path)
                }
                resolved.append(component)
                continue
            }
            hops += 1
            guard hops <= Self.maximumSymlinkHops else { throw CleanupFileSystemError.symlinkLoop(url.path) }
            let target = try destination(candidate)
            guard !target.isEmpty else { throw CleanupFileSystemError.notFound(candidate.path) }
            guard !CleanupPathText.containsNUL(target) else {
                throw CleanupFileSystemError.protectedLocation(candidate.path)
            }
            if CleanupPathText.isAbsolute(target) { resolved.removeAll() }
            pending.insert(contentsOf: CleanupPathText.components(of: target), at: 0)
        }
        return Self.url(resolved)
    }

    private static func url(_ components: [String]) -> URL {
        URL(filePath: "/" + components.joined(separator: "/"), directoryHint: .notDirectory)
    }
}

/// The production adapter. `trash` hands the item to the injected closure, which moves it to the
/// Trash; nothing here deletes.
public struct LiveCleanupFileSystem: CleanupFileSystem {
    private static let sizeKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    private let trashItem: @Sendable (URL) throws -> Void

    public init(trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        trashItem = trash
    }

    private var resolver: CleanupPathResolver {
        CleanupPathResolver(check: { _ in }, entry: entry(at:), destination: symlinkDestination(of:))
    }

    public func entry(at url: URL) throws -> CleanupEntry? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw CleanupFileSystemError.io("\(url.path): \(String(cString: strerror(code)))")
        }
        return CleanupEntry(url: url, status: status)
    }

    public func contents(of directory: URL) throws -> [CleanupEntry] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw Self.mapped(error, directory)
        }
        return try names.sorted().compactMap { name in
            try entry(at: directory.appending(component: name, directoryHint: .notDirectory))
        }
    }

    public func symlinkDestination(of url: URL) throws -> String {
        do {
            return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        } catch {
            throw Self.mapped(error, url)
        }
    }

    public func realpath(_ url: URL) throws -> URL {
        try resolver.resolve(url)
    }

    public func allocatedSize(of url: URL) throws -> Int64 {
        guard let item = try entry(at: url) else { throw CleanupFileSystemError.notFound(url.path) }
        guard item.kind == .directory else { return try Self.ownAllocatedSize(of: url) }
        return try Self.treeAllocatedSize(of: url)
    }

    public func readData(_ url: URL, maxBytes: Int) throws -> Data {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            throw Self.mapped(error, url)
        }
        guard data.count <= maxBytes else {
            throw CleanupFileSystemError.io("\(url.path): larger than \(maxBytes) bytes")
        }
        return data
    }

    public func readText(_ url: URL, maxBytes: Int) throws -> String {
        let data = try readData(url, maxBytes: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CleanupFileSystemError.io("\(url.path): not UTF-8 text")
        }
        return text
    }

    public func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw Self.mapped(error, url)
        }
    }

    public func moveItem(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw Self.mapped(error, source)
        }
    }

    public func trash(_ url: URL) throws {
        do {
            try trashItem(url)
        } catch {
            throw Self.mapped(error, url)
        }
    }

    /// Resource values describe the item itself; they never follow a symlink.
    private static func ownAllocatedSize(of url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: Set(sizeKeys))
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        } catch {
            throw mapped(error, url)
        }
    }

    /// The URL enumerator lists links as items and does not descend into linked directories.
    private static func treeAllocatedSize(of directory: URL) throws -> Int64 {
        var failure: Error?
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: sizeKeys, options: [],
            errorHandler: { _, error in
                failure = error
                return false
            }
        )
        guard let enumerator else { throw CleanupFileSystemError.io("\(directory.path): not enumerable") }
        var total: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            total += try ownAllocatedSize(of: item)
        }
        if let failure { throw mapped(failure, directory) }
        return total
    }

    private static func mapped(_ error: Error, _ url: URL) -> CleanupFileSystemError {
        if let error = error as? CleanupFileSystemError { return error }
        let error = error as NSError
        let isMissing = (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
        return isMissing ? .notFound(url.path) : .io("\(url.path): \(error.domain) \(error.code)")
    }
}

/// Checks every argument with the `ProtectedLocationGuard` before the base sees it. Because the
/// kernel follows links in the middle of a path, each argument's physical location is resolved
/// first, through the base's `entry` and `symlinkDestination`, checking every hop — so behind a
/// link such as `~/bin` → `~/Documents/bin` nothing is read. `realpath` is answered here the
/// same way and never reaches the base's own `realpath`.
public struct GuardedCleanupFileSystem: CleanupFileSystem {
    private let base: CleanupFileSystem
    private let locationGuard: ProtectedLocationGuard

    public init(base: CleanupFileSystem, guard locationGuard: ProtectedLocationGuard) {
        self.base = base
        self.locationGuard = locationGuard
    }

    private var resolver: CleanupPathResolver {
        CleanupPathResolver(check: locationGuard.check, entry: base.entry(at:), destination: base.symlinkDestination(of:))
    }

    public func entry(at url: URL) throws -> CleanupEntry? {
        do {
            _ = try resolver.locate(url)
        } catch CleanupFileSystemError.notFound {
            return nil
        }
        return try base.entry(at: url)
    }

    public func contents(of directory: URL) throws -> [CleanupEntry] {
        _ = try resolver.resolve(directory)
        return try base.contents(of: directory)
    }

    public func symlinkDestination(of url: URL) throws -> String {
        _ = try resolver.locate(url)
        return try base.symlinkDestination(of: url)
    }

    public func realpath(_ url: URL) throws -> URL {
        try resolver.resolve(url)
    }

    public func allocatedSize(of url: URL) throws -> Int64 {
        try locationGuard.checkSubtree(resolver.locate(url))
        return try base.allocatedSize(of: url)
    }

    public func readData(_ url: URL, maxBytes: Int) throws -> Data {
        _ = try resolver.resolve(url)
        return try base.readData(url, maxBytes: maxBytes)
    }

    public func readText(_ url: URL, maxBytes: Int) throws -> String {
        _ = try resolver.resolve(url)
        return try base.readText(url, maxBytes: maxBytes)
    }

    public func createDirectory(_ url: URL) throws {
        _ = try resolver.locate(url)
        try base.createDirectory(url)
    }

    public func moveItem(_ source: URL, to destination: URL) throws {
        try locationGuard.checkSubtree(resolver.locate(source))
        _ = try resolver.locate(destination)
        try base.moveItem(source, to: destination)
    }

    public func trash(_ url: URL) throws {
        try locationGuard.checkSubtree(resolver.locate(url))
        try base.trash(url)
    }
}

private extension CleanupEntry {
    init(url: URL, status: stat) {
        let mode = status.st_mode
        let modified = status.st_mtimespec
        self.init(
            url: url,
            kind: CleanupEntryKind(mode: mode),
            isExecutable: mode & S_IXUSR != 0,
            identity: CleanupFileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino)),
            modificationDate: Date(timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1_000_000_000)
        )
    }
}

private extension CleanupEntryKind {
    init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFREG: self = .file
        case S_IFDIR: self = .directory
        case S_IFLNK: self = .symlink
        default: self = .other
        }
    }
}
