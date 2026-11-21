import Darwin
import Foundation

/// The folders and files launchd follows to start the helper as root, in the order the gate checks
/// them: every folder before what it holds.
public enum HelperBundleEntry: CaseIterable, Sendable {
    case bundle, contents, macOS, helperExecutable, library, launchDaemons, launchdPlist

    /// The folder that holds the entry; `nil` for the bundle itself.
    public var parent: HelperBundleEntry? {
        switch self {
        case .bundle: nil
        case .contents: .bundle
        case .macOS, .library: .contents
        case .helperExecutable: .macOS
        case .launchDaemons: .library
        case .launchdPlist: .launchDaemons
        }
    }

    /// The entry's name inside its parent; empty for the bundle itself.
    public var name: String {
        switch self {
        case .bundle: ""
        case .contents: "Contents"
        case .macOS: "MacOS"
        case .helperExecutable: HelperBundleGate.helperExecutableName
        case .library: "Library"
        case .launchDaemons: "LaunchDaemons"
        case .launchdPlist: WegaHelper.plistName
        }
    }

    /// The path under the bundle; empty for the bundle itself.
    public var relativePath: String {
        guard let parent else { return "" }
        return parent.relativePath.isEmpty ? name : parent.relativePath + "/" + name
    }

    public var isDirectory: Bool {
        self != .helperExecutable && self != .launchdPlist
    }
}

/// One entry as `lstat` and its descriptor report it.
public struct HelperBundleEntryFacts: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case directory, regularFile, symbolicLink, other }

    public var kind: Kind
    public var ownerUID: UInt32
    /// `st_mode & 0o7777`.
    public var permissions: UInt16
    public var accessControl: PAMAccessControlState

    public init(kind: Kind, ownerUID: UInt32, permissions: UInt16, accessControl: PAMAccessControlState) {
        self.kind = kind
        self.ownerUID = ownerUID
        self.permissions = permissions
        self.accessControl = accessControl
    }
}

/// Why the helper may not run from a bundle.
public enum HelperBundleRefusal: Equatable, Sendable {
    /// The bundle is not `/Applications/<name>.app`, spelled plainly.
    case notInApplications
    case unreadable(HelperBundleEntry)
    case symbolicLink(HelperBundleEntry)
    case unexpectedKind(HelperBundleEntry)
    case notOwnedByRoot(HelperBundleEntry)
    case writableByGroupOrOthers(HelperBundleEntry)
    /// An extended ACL is present, or could not be read.
    case accessControlList(HelperBundleEntry)
}

public enum HelperBundleTrust: Equatable, Sendable {
    case trusted
    case refused(HelperBundleRefusal)
}

/// Z14: whether the helper may run from a bundle, decided from facts alone.
///
/// A drag-installed bundle belongs to the user, so code running as the user could replace the
/// helper binary or its launchd plist, and launchd would start the replacement as root. The app
/// neither registers nor uses the helper, and the helper serves no one, unless the bundle is
/// directly in `/Applications` and every entry launchd runs the helper from belongs to root, is not
/// a link, is of its expected kind and cannot be changed by its group, by others or through an ACL.
public enum HelperBundleGate {
    static let helperExecutableName = "WegaPrivilegedHelper"

    /// Checks the location first, then the entries in order. `facts` is asked for an entry only once
    /// every folder above it has passed, so a live reader never resolves a name through a folder that
    /// someone other than root could change. `nil` facts mean the entry is missing or unreadable.
    public static func trust(
        bundlePath: String, facts: (HelperBundleEntry) -> HelperBundleEntryFacts?
    ) -> HelperBundleTrust {
        guard isApplicationsEntry(bundlePath) else { return .refused(.notInApplications) }
        for entry in HelperBundleEntry.allCases {
            guard let entryFacts = facts(entry) else { return .refused(.unreadable(entry)) }
            if let refusal = refusal(of: entryFacts, as: entry) { return .refused(refusal) }
        }
        return .trusted
    }

    /// Exactly `/Applications/<name>.app`, read as UTF-8 bytes the way the kernel reads it, with
    /// every component a real name. Any other spelling refuses, even one that resolves to the same
    /// folder: the gate approves only the string it was given.
    public static func isApplicationsEntry(_ path: String) -> Bool {
        guard WegaHelper.namesEveryComponentPlainly(path) else { return false }
        let components = path.utf8.split(separator: pathSeparator)
        guard components.count == 2, components[0].elementsEqual("Applications".utf8) else { return false }
        let name = components[1]
        return name.count > applicationSuffix.count && name.reversed().starts(with: applicationSuffix.reversed())
    }

    /// The bundle an executable at `<bundle>/Contents/MacOS/WegaPrivilegedHelper` belongs to; `nil`
    /// for an executable anywhere else.
    public static func bundlePath(ofHelperExecutable path: String) -> String? {
        let bytes = Array(path.utf8)
        let suffix = Array(executableSuffix.utf8)
        guard bytes.count > suffix.count, bytes.reversed().starts(with: suffix.reversed()) else { return nil }
        let bundle = bytes.dropLast(suffix.count)
        guard bundle.first == pathSeparator else { return nil }
        return String(decoding: bundle, as: UTF8.self)
    }

    private static func refusal(of facts: HelperBundleEntryFacts, as entry: HelperBundleEntry) -> HelperBundleRefusal? {
        if facts.kind == .symbolicLink { return .symbolicLink(entry) }
        if facts.kind != (entry.isDirectory ? .directory : .regularFile) { return .unexpectedKind(entry) }
        if facts.ownerUID != 0 { return .notOwnedByRoot(entry) }
        if facts.permissions & groupOrOthersWrite != 0 { return .writableByGroupOrOthers(entry) }
        if facts.accessControl != .absent { return .accessControlList(entry) }
        return nil
    }

    private static let groupOrOthersWrite: UInt16 = 0o022
    private static let pathSeparator = UInt8(ascii: "/")
    private static let applicationSuffix = Array(".app".utf8)
    private static let executableSuffix = "/" + HelperBundleEntry.helperExecutable.relativePath
}

/// Reads the entries of one bundle for `HelperBundleGate`, through descriptors.
///
/// The bundle is `lstat`ed and opened with `O_NOFOLLOW_ANY`; every other entry is `fstatat`ed and
/// opened in its folder's descriptor with `O_NOFOLLOW`. The opened descriptor must show the device
/// and inode the name pointed at, and the ACL is read from it, where only `ENOENT` means none
/// (`PAMAccessControlState`). A link, a FIFO or any other kind is reported without being opened, and
/// only a folder's descriptor is kept, so nothing below a link or a file is ever read. Ask for an
/// entry only after its folder, as the gate does; `nil` means missing, unreadable or changed.
public final class HelperBundleReader {
    private let bundlePath: String
    private var folders: [HelperBundleEntry: Int32] = [:]

    public init(bundlePath: String) {
        self.bundlePath = bundlePath
    }

    deinit {
        for descriptor in folders.values { close(descriptor) }
    }

    public func facts(of entry: HelperBundleEntry) -> HelperBundleEntryFacts? {
        var named = stat()
        let folder = entry.parent.flatMap { folders[$0] }
        if entry.parent == nil {
            guard lstat(bundlePath, &named) == 0 else { return nil }
        } else {
            guard let folder, fstatat(folder, entry.name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        }
        let kind = Self.kind(of: named)
        guard kind == .directory || kind == .regularFile else {
            return Self.facts(named, kind: kind, accessControl: .unreadable)
        }
        let flags = O_RDONLY | O_CLOEXEC | (kind == .directory ? O_DIRECTORY : O_NONBLOCK)
        let descriptor = folder.map { openat($0, entry.name, flags | O_NOFOLLOW) }
            ?? open(bundlePath, flags | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { return nil }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, Self.isSameEntry(opened, named) else {
            close(descriptor)
            return nil
        }
        let facts = Self.facts(opened, kind: kind, accessControl: SystemPAMPolicyDirectory.accessControl(of: descriptor))
        if kind == .directory {
            folders[entry] = descriptor
        } else {
            close(descriptor)
        }
        return facts
    }

    private static func kind(of status: stat) -> HelperBundleEntryFacts.Kind {
        switch status.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .regularFile
        case S_IFLNK: .symbolicLink
        default: .other
        }
    }

    private static func isSameEntry(_ opened: stat, _ named: stat) -> Bool {
        opened.st_dev == named.st_dev && opened.st_ino == named.st_ino && opened.st_mode & S_IFMT == named.st_mode & S_IFMT
    }

    private static func facts(
        _ status: stat, kind: HelperBundleEntryFacts.Kind, accessControl: PAMAccessControlState
    ) -> HelperBundleEntryFacts {
        HelperBundleEntryFacts(
            kind: kind, ownerUID: status.st_uid, permissions: UInt16(status.st_mode & 0o7777), accessControl: accessControl
        )
    }
}

extension HelperBundleGate {
    /// The gate over the live file system: the location first, then each entry through
    /// `HelperBundleReader`. Pass `Bundle.main.bundlePath`, never a URL's `path(percentEncoded:)`,
    /// which keeps a directory's trailing `/`.
    public static func live(bundlePath: String) -> HelperBundleTrust {
        guard isApplicationsEntry(bundlePath) else { return .refused(.notInApplications) }
        let reader = HelperBundleReader(bundlePath: bundlePath)
        return trust(bundlePath: bundlePath, facts: reader.facts(of:))
    }
}

extension HelperBundleGate {
    /// The helper's own check (design §5): the gate over the bundle this process was started from,
    /// found from the kernel's path of its executable. Called once at start.
    public static func trustOfThisHelper() -> HelperBundleTrust {
        trust(ofHelperExecutable: executablePathOfThisProcess() ?? "")
    }

    /// The gate over the bundle a helper at `path` runs from; an executable that is not
    /// `<bundle>/Contents/MacOS/WegaPrivilegedHelper` cannot establish its bundle and is refused.
    public static func trust(ofHelperExecutable path: String) -> HelperBundleTrust {
        guard let bundle = bundlePath(ofHelperExecutable: path) else { return .refused(.unreadable(.helperExecutable)) }
        return live(bundlePath: bundle)
    }

    /// `proc_pidpath` of this process: the path of the file the kernel runs, as it resolved it.
    public static func executablePathOfThisProcess() -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, a macro Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension HelperBundleRefusal {
    /// A stable English token for logs and diagnostics: the refusal and the entry under the bundle,
    /// never a path that could name the user.
    public var token: String {
        switch self {
        case .notInApplications: "notInApplications"
        case .unreadable(let entry): "unreadable(\(entry.token))"
        case .symbolicLink(let entry): "symbolicLink(\(entry.token))"
        case .unexpectedKind(let entry): "unexpectedKind(\(entry.token))"
        case .notOwnedByRoot(let entry): "notOwnedByRoot(\(entry.token))"
        case .writableByGroupOrOthers(let entry): "writableByGroupOrOthers(\(entry.token))"
        case .accessControlList(let entry): "accessControlList(\(entry.token))"
        }
    }

    /// The entry the refusal is about; `nil` for the bundle's location.
    public var entry: HelperBundleEntry? {
        switch self {
        case .notInApplications: nil
        case .unreadable(let entry), .symbolicLink(let entry), .unexpectedKind(let entry), .notOwnedByRoot(let entry),
             .writableByGroupOrOthers(let entry), .accessControlList(let entry): entry
        }
    }
}

extension HelperBundleTrust {
    public var token: String {
        switch self {
        case .trusted: "trusted"
        case .refused(let refusal): refusal.token
        }
    }
}

private extension HelperBundleEntry {
    var token: String { relativePath.isEmpty ? "bundle" : relativePath }
}
