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
