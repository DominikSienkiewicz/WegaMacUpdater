import Darwin
import Foundation
@testable import MacUpdaterCore

/// A throwaway home directory for Cleanup tests, removed when the value is released.
///
/// The path is resolved with realpath(3) first: the temporary directory sits behind
/// `/var` → `/private/var`, and the guarded file system compares physical paths.
final class CleanupTempHome: Sendable {
    let home: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CleanupTempHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let resolved = Darwin.realpath(root.path, nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        defer { free(resolved) }
        home = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    /// `relative` is resolved against the home without consulting the file system.
    func url(_ relative: String) -> URL {
        home.appending(path: relative, directoryHint: .notDirectory)
    }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A regular file of `size` bytes; intermediate directories are created.
    @discardableResult
    func file(_ relative: String, size: Int = 0, executable: Bool = false) throws -> URL {
        try write(Data(repeating: 0x61, count: size), to: relative, executable: executable)
    }

    @discardableResult
    func file(_ relative: String, text: String, executable: Bool = false) throws -> URL {
        try write(Data(text.utf8), to: relative, executable: executable)
    }

    /// A symlink whose destination is stored verbatim, so relative destinations stay relative.
    @discardableResult
    func symlink(_ relative: String, to destination: String) throws -> URL {
        let url = url(relative)
        try createParent(of: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    private func write(_ data: Data, to relative: String, executable: Bool) throws -> URL {
        let url = url(relative)
        try createParent(of: url)
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path
        )
        return url
    }

    private func createParent(of url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }
}

/// Records every URL argument it receives, as standardised path strings, then delegates.
final class RecordingCleanupFileSystem: CleanupFileSystem, @unchecked Sendable {
    private let base: CleanupFileSystem
    private let lock = NSLock()
    private var recorded: [String] = []

    init(wrapping base: CleanupFileSystem) {
        self.base = base
    }

    var touched: [String] {
        lock.withLock { recorded }
    }

    func entry(at url: URL) throws -> CleanupEntry? {
        record(url)
        return try base.entry(at: url)
    }

    func contents(of directory: URL) throws -> [CleanupEntry] {
        record(directory)
        return try base.contents(of: directory)
    }

    func symlinkDestination(of url: URL) throws -> String {
        record(url)
        return try base.symlinkDestination(of: url)
    }

    func realpath(_ url: URL) throws -> URL {
        record(url)
        return try base.realpath(url)
    }

    func allocatedSize(of url: URL) throws -> Int64 {
        record(url)
        return try base.allocatedSize(of: url)
    }

    func readText(_ url: URL, maxBytes: Int) throws -> String {
        record(url)
        return try base.readText(url, maxBytes: maxBytes)
    }

    func createDirectory(_ url: URL) throws {
        record(url)
        try base.createDirectory(url)
    }

    func moveItem(_ source: URL, to destination: URL) throws {
        record(source, destination)
        try base.moveItem(source, to: destination)
    }

    func trash(_ url: URL) throws {
        record(url)
        try base.trash(url)
    }

    private func record(_ urls: URL...) {
        let paths = urls.map(ProtectedLocationGuard.standardizedPath)
        lock.withLock { recorded.append(contentsOf: paths) }
    }
}

struct FixedMountTable: MountTableReading {
    let points: [String]

    init(_ points: [String]) {
        self.points = points
    }

    func mountPoints() -> [String] {
        points
    }
}

/// Stands in for the Trash: records each URL and leaves the item where it is.
final class RecordingTrash: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    var urls: [URL] {
        lock.withLock { recorded }
    }

    func record(_ url: URL) {
        lock.withLock { recorded.append(url) }
    }
}

struct FakeProcessInspector: ProcessInspecting {
    let processes: [CleanupProcess]
    let boot: Date

    init(processes: [CleanupProcess], bootTime: Date) {
        self.processes = processes
        boot = bootTime
    }

    func userProcesses() -> [CleanupProcess] { processes }

    func bootTime() -> Date { boot }
}

private struct FixedTextUnsupported: Error {}

/// Serves fixed text files, directory listings and existing paths; every other call throws.
struct FixedTextCleanupFileSystem: CleanupFileSystem {
    let texts: [String: String]
    let children: [String: [String]]
    let existing: Set<String>

    init(texts: [String: String] = [:], children: [String: [String]] = [:], existing: Set<String> = []) {
        self.texts = texts
        self.children = children
        self.existing = existing
    }

    func entry(at url: URL) throws -> CleanupEntry? {
        guard existing.contains(url.path) else { return nil }
        return CleanupEntry(
            url: url, kind: .directory, isExecutable: true,
            identity: CleanupFileIdentity(device: 1, inode: 1), modificationDate: nil
        )
    }

    func contents(of directory: URL) throws -> [CleanupEntry] {
        guard let names = children[directory.path] else { throw FixedTextUnsupported() }
        return names.map {
            CleanupEntry(
                url: directory.appending(path: $0, directoryHint: .notDirectory), kind: .file, isExecutable: false,
                identity: CleanupFileIdentity(device: 1, inode: 1), modificationDate: nil
            )
        }
    }

    func readText(_ url: URL, maxBytes: Int) throws -> String {
        guard let text = texts[url.path] else { throw FixedTextUnsupported() }
        return text
    }

    func symlinkDestination(of url: URL) throws -> String { throw FixedTextUnsupported() }
    func realpath(_ url: URL) throws -> URL { throw FixedTextUnsupported() }
    func allocatedSize(of url: URL) throws -> Int64 { throw FixedTextUnsupported() }
    func createDirectory(_ url: URL) throws { throw FixedTextUnsupported() }
    func moveItem(_ source: URL, to destination: URL) throws { throw FixedTextUnsupported() }
    func trash(_ url: URL) throws { throw FixedTextUnsupported() }
}
