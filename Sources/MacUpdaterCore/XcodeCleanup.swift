import Foundation

public struct XcodeCleanupItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case derivedData, archive }
    public var id: URL { url }
    public let url: URL
    public let kind: Kind
    public let name: String
    public let sizeBytes: Int64?
    public let lastModified: Date
    public let canTrash: Bool

    fileprivate let identity: CleanupFileIdentity
    fileprivate let tree: XcodeCleanupTree?
}

private enum XcodeCleanupError: Error {
    case notProjectCache, changedSinceScan
}

public struct XcodeCleanup: Sendable {
    private let home: URL
    private let now: @Sendable () -> Date
    private let processes: @Sendable () -> [CleanupProcess]
    private let fileSystem: GuardedCleanupFileSystem
    private let locationGuard: ProtectedLocationGuard
    private static let quietPeriod: TimeInterval = 60 * 60

    public init() {
        self.init(home: FileManager.default.homeDirectoryForCurrentUser, now: { Date() },
                  processes: { LiveProcessInspector().userProcesses() },
                  trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    }

    init(home: URL, now: @escaping @Sendable () -> Date, processes: @escaping @Sendable () -> [CleanupProcess] = { [] },
         trash: @escaping @Sendable (URL) throws -> Void) {
        self.home = home
        self.now = now
        self.processes = processes
        self.locationGuard = ProtectedLocationGuard(home: home, mounts: LiveMountTable())
        self.fileSystem = GuardedCleanupFileSystem(base: LiveCleanupFileSystem(trash: trash), guard: locationGuard)
    }

    public func scan() async throws -> [XcodeCleanupItem] {
        try Task.checkCancellation()
        var items: [XcodeCleanupItem] = []
        if let derivedData = try directory("DerivedData") {
            for entry in try fileSystem.contents(of: derivedData.url) where entry.kind == .directory {
                try Task.checkCancellation()
                if let item = try projectItem(entry) { items.append(item) }
            }
        }
        if let archives = try directory("Archives") {
            let children = try fileSystem.contents(of: archives.url)
            for child in children where child.kind == .directory {
                try Task.checkCancellation()
                if child.url.pathExtension == "xcarchive" {
                    items.append(try archiveItem(child))
                } else if child.url.lastPathComponent.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil {
                    for archive in try fileSystem.contents(of: child.url)
                    where archive.kind == .directory && archive.url.pathExtension == "xcarchive" {
                        items.append(try archiveItem(archive))
                    }
                }
            }
        }
        return items
    }

    public func trash(_ item: XcodeCleanupItem) async throws {
        try Task.checkCancellation()
        guard item.kind == .derivedData, item.canTrash, let root = try directory("DerivedData"),
              item.url.deletingLastPathComponent().path == root.url.path else { throw XcodeCleanupError.notProjectCache }
        guard let entry = try fileSystem.entry(at: item.url), entry.kind == .directory, entry.identity == item.identity,
              let current = try projectItem(entry), current == item else { throw XcodeCleanupError.changedSinceScan }
        try Task.checkCancellation()
        let physicalHome = try fileSystem.realpath(home)
        let expectedPath = physicalHome.appending(path: "Library/Developer/Xcode/DerivedData")
            .appending(component: item.url.lastPathComponent, directoryHint: .isDirectory)
        let running = processes()
        guard CleanupInUseMatcher.processes(using: item.url, isDirectory: true, among: running).isEmpty,
              CleanupInUseMatcher.processes(referencing: item.url, among: running).isEmpty,
              try fileSystem.realpath(item.url).path == expectedPath.path,
              try fileSystem.entry(at: item.url) == entry else { throw XcodeCleanupError.changedSinceScan }
        try Task.checkCancellation()
        try fileSystem.trash(item.url)
    }

    private func directory(_ name: String) throws -> CleanupEntry? {
        var url = home
        var result: CleanupEntry?
        for component in ["Library", "Developer", "Xcode", name] {
            url = url.appending(component: component, directoryHint: .isDirectory)
            guard let entry = try fileSystem.entry(at: url) else { return nil }
            guard entry.kind == .directory else { throw CocoaError(.fileReadUnsupportedScheme) }
            result = entry
        }
        return result
    }

    private func projectItem(_ entry: CleanupEntry) throws -> XcodeCleanupItem? {
        let metadata = entry.url.appending(component: "info.plist", directoryHint: .notDirectory)
        if entry.url.pathExtension == "noindex" { return nil }
        guard let marker = try fileSystem.entry(at: metadata) else { return try cacheWithoutMetadata(entry) }
        guard marker.kind == .file else { return nil }
        let data = try fileSystem.readData(metadata, maxBytes: 1_048_576)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = plist["WorkspacePath"] as? String, path.hasPrefix("/"), !path.contains("\0") else { return nil }

        let workspace = URL(filePath: path, directoryHint: .notDirectory)
        let pathKey = ProtectedLocationGuard.standardizedPath(workspace).lowercased()
        let cacheKey = ProtectedLocationGuard.standardizedPath(entry.url).lowercased()
        let sourceIsOutside = pathKey != cacheKey && !pathKey.hasPrefix(cacheKey + "/")
        let container = workspace.lastPathComponent == "project.xcworkspace" ? workspace.deletingLastPathComponent() : workspace
        let name = container.deletingPathExtension().lastPathComponent
        let recognizedWorkspace = ["xcodeproj", "xcworkspace", "playground", "swiftpm"].contains(workspace.pathExtension.lowercased())
            || workspace.lastPathComponent == "Package.swift"
        return try item(entry, kind: .derivedData, name: name.isEmpty ? entry.url.lastPathComponent : name,
                        projectCache: recognizedWorkspace && sourceIsOutside)
    }

    private func cacheWithoutMetadata(_ entry: CleanupEntry) throws -> XcodeCleanupItem? {
        let directoryName = entry.url.lastPathComponent
        guard let separator = directoryName.lastIndex(of: "-"), separator != directoryName.startIndex,
              directoryName[directoryName.index(after: separator)...].wholeMatch(of: /[a-z]{28}/) != nil,
              try fileSystem.entry(at: entry.url.appending(component: "Build", directoryHint: .isDirectory))?.kind == .directory
        else { return nil }
        return try item(entry, kind: .derivedData, name: String(directoryName[..<separator]), projectCache: false)
    }

    private func archiveItem(_ entry: CleanupEntry) throws -> XcodeCleanupItem {
        try item(entry, kind: .archive, name: entry.url.deletingPathExtension().lastPathComponent, projectCache: false)
    }

    private func item(_ entry: CleanupEntry, kind: XcodeCleanupItem.Kind, name: String, projectCache: Bool) throws -> XcodeCleanupItem {
        try Task.checkCancellation()
        try locationGuard.checkSubtree(entry.url)
        let tree: XcodeCleanupTree?
        do {
            tree = try XcodeCleanupTree.measure(entry)
        } catch {
            try Task.checkCancellation()
            tree = nil
        }
        let date = tree?.lastModified ?? entry.modificationDate ?? .distantPast
        let canTrash = projectCache && tree?.hasOnlyCacheContents == true && now().timeIntervalSince(date) >= Self.quietPeriod
        return XcodeCleanupItem(url: entry.url, kind: kind, name: name, sizeBytes: tree?.allocatedBytes,
                                lastModified: date, canTrash: canTrash, identity: entry.identity, tree: tree)
    }
}
