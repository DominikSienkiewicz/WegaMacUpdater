import Darwin
import Foundation

public enum OldInstallerAge: Sendable {
    case olderThan30Days, all

    fileprivate func includes(_ modifiedAt: Date, now: Date) -> Bool {
        self == .all || now.timeIntervalSince(modifiedAt) >= 30 * 24 * 60 * 60
    }
}

public struct OldInstaller: Equatable, Identifiable, Sendable {
    public let name: String
    public let size: Int64
    public let modifiedAt: Date
    public let installedVersion: String?
    fileprivate let fingerprint: OldInstallerFingerprint

    public var id: String { "\(fingerprint.identity.device):\(fingerprint.identity.inode):\(name)" }
}

public struct OldInstallerScan: Sendable {
    public let directory: URL
    public let installers: [OldInstaller]
    public let age: OldInstallerAge
    fileprivate let identity: CleanupFileIdentity
}

public enum OldInstallerError: Error { case folderUnavailable, itemChanged, trashFailed }

public actor OldInstallerScanner {
    private let now: @Sendable () -> Date
    private let moveToTrash: @Sendable (URL) throws -> Void
    private let installedVersion: @Sendable (URL) -> String?

    public init() {
        self.init(now: { .now }, trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                  installedVersion: OldInstallerVersionEvidence.installedVersion)
    }

    init(now: @escaping @Sendable () -> Date, trash: @escaping @Sendable (URL) throws -> Void,
         installedVersion: @escaping @Sendable (URL) -> String? = { _ in nil }) {
        self.now = now
        self.moveToTrash = trash
        self.installedVersion = installedVersion
    }

    public func scan(directory: URL, age: OldInstallerAge = .olderThan30Days) throws -> OldInstallerScan {
        let folder = try OldInstallerDirectory(directory)
        let referenceDate = now()
        let evidenceDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var installers: [OldInstaller] = []
        try folder.forEachName { name in
            guard Self.supports(name), let fingerprint = folder.regularFile(named: name),
                  age.includes(fingerprint.modifiedAt, now: referenceDate) else { return }
            var version: String?
            if !fingerprint.isDataless, ContinuousClock.now < evidenceDeadline, (name as NSString).pathExtension.lowercased() == "pkg" {
                version = folder.withPinnedPackage(name: name, matching: fingerprint, read: installedVersion)
            }
            installers.append(OldInstaller(
                name: name, size: fingerprint.size, modifiedAt: fingerprint.modifiedAt,
                installedVersion: version, fingerprint: fingerprint
            ))
        }
        return OldInstallerScan(directory: directory, installers: installers, age: age, identity: folder.identity)
    }

    public func trash(_ item: OldInstaller, from scan: OldInstallerScan) throws {
        try Task.checkCancellation()
        guard scan.installers.contains(item), Self.supports(item.name) else { throw OldInstallerError.itemChanged }
        let folder = try OldInstallerDirectory(scan.directory)
        guard folder.identity == scan.identity else { throw OldInstallerError.folderUnavailable }
        guard folder.regularFile(named: item.name) == item.fingerprint, scan.age.includes(item.modifiedAt, now: now()) else {
            throw OldInstallerError.itemChanged
        }

        let path = scan.directory.appending(component: item.name, directoryHint: .notDirectory)
        // Foundation resolves a file reference by identity during the move. A replacement
        // at the original name must not become the object we send to the Trash.
        guard let reference = (item.fingerprint.volumeRelativeURL as NSURL).fileReferenceURL() as NSURL?,
              let resolved = reference.filePathURL,
              InstallationIdentity(path: resolved) == InstallationIdentity(path: path),
              try OldInstallerDirectory(scan.directory).identity == folder.identity,
              folder.regularFile(named: item.name) == item.fingerprint else {
            throw OldInstallerError.itemChanged
        }
        do { try moveToTrash(reference as URL) }
        catch { throw OldInstallerError.trashFailed }
    }

    private static func supports(_ name: String) -> Bool {
        switch (name as NSString).pathExtension.lowercased() {
        case "dmg", "pkg": true
        default: false
        }
    }
}

private struct OldInstallerFingerprint: Sendable, Equatable {
    let identity: CleanupFileIdentity
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let createdSeconds: Int
    let createdNanos: Int
    let isDataless: Bool

    init(_ status: stat) {
        identity = fileIdentity(status)
        size = status.st_size
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanos = status.st_mtimespec.tv_nsec
        createdSeconds = status.st_birthtimespec.tv_sec
        createdNanos = status.st_birthtimespec.tv_nsec
        isDataless = status.st_flags & UInt32(SF_DATALESS) != 0
    }

    var volumeRelativeURL: URL {
        URL(filePath: "/.vol/\(identity.device)/\(identity.inode)", directoryHint: .notDirectory)
    }

    var modifiedAt: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanos) / 1_000_000_000)
    }
}

private func fileIdentity(_ status: stat) -> CleanupFileIdentity {
    CleanupFileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: status.st_ino)
}

private final class OldInstallerDirectory: Sendable {
    let identity: CleanupFileIdentity
    private let descriptor: Int32

    init(_ url: URL) throws {
        guard url.isFileURL, url.host().map({ $0.isEmpty || $0 == "localhost" }) ?? true, !url.path(percentEncoded: true).contains("%00") else { throw OldInstallerError.folderUnavailable }
        let opened = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard opened >= 0 else { throw OldInstallerError.folderUnavailable }
        var status = stat()
        guard Darwin.fstat(opened, &status) == 0 else {
            Darwin.close(opened)
            throw OldInstallerError.folderUnavailable
        }
        descriptor = opened
        identity = fileIdentity(status)
    }

    deinit { Darwin.close(descriptor) }

    func forEachName(_ visit: (String) -> Void) throws {
        let copy = Darwin.dup(descriptor)
        guard copy >= 0 else { throw OldInstallerError.folderUnavailable }
        guard let stream = Darwin.fdopendir(copy) else {
            Darwin.close(copy)
            throw OldInstallerError.folderUnavailable
        }
        defer { Darwin.closedir(stream) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else { throw OldInstallerError.folderUnavailable }
                return
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            if let name { visit(name) }
        }
    }

    /// Keep the inode open while the system tools read it. A replaced path or symlink
    /// cannot redirect either query. File systems without a volume-relative reference
    /// still contribute normal review rows, with no version hint.
    func withPinnedPackage(name: String, matching fingerprint: OldInstallerFingerprint, read: (URL) -> String?) -> String? {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_flags & UInt32(SF_DATALESS) == 0, OldInstallerFingerprint(initial) == fingerprint else { return nil }
        var magic = [UInt8](repeating: 0, count: 4)
        guard Darwin.pread(fd, &magic, 4, 0) == 4, magic == Array("xar!".utf8) else { return nil }
        let pinned = fingerprint.volumeRelativeURL
        var actual = stat()
        guard Darwin.lstat(pinned.path, &actual) == 0, OldInstallerFingerprint(actual) == fingerprint else { return nil }
        let version = read(pinned)
        return regularFile(named: name) == fingerprint ? version : nil
    }

    func regularFile(named name: String) -> OldInstallerFingerprint? {
        var status = stat()
        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return OldInstallerFingerprint(status)
    }
}
