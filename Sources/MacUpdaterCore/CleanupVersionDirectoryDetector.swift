import Foundation

/// D3: old versions kept by a tool's own installer, copies owned by an application, and version
/// directories that no known layout explains. Only recognised layouts ever offer the Trash.
public struct CleanupVersionDirectoryDetector: Sendable {
    private struct Child {
        let entry: CleanupEntry
        let realpath: URL
        var name: String { entry.url.lastPathComponent }
    }

    private struct Verdict {
        let status: CleanupStatus
        let reason: CleanupReason
        let action: CleanupAction
        let risk: CleanupRisk
        let relation: CleanupVersionRelation
        let recognised: Bool
        let sized: Bool
    }

    private struct HeuristicDirectory {
        let directory: URL
        let tool: String
        var realpaths: [URL] = []
    }

    private let fileSystem: CleanupFileSystem
    private let home: URL
    private let inspector: ProcessInspecting

    public init(fileSystem: CleanupFileSystem, home: URL, inspector: ProcessInspecting) {
        self.fileSystem = fileSystem
        self.home = home
        self.inspector = inspector
    }

    public func findings(pathScan: CleanupPathScan) -> [CleanupFinding] {
        let processes = inspector.userProcesses()
        let copyRealpaths = pathScan.groups.flatMap(\.copies).compactMap(\.realpath)
        var recognisedRoots: [[String]] = []
        var result: [CleanupFinding] = []
        for layout in CleanupKnownLayouts.nativeVersionDirectories {
            let directory = home.appending(path: layout.versionsDirectory, directoryHint: .isDirectory)
            guard let root = try? fileSystem.realpath(directory) else { continue }
            recognisedRoots.append(CleanupPathText.components(of: root.path))
            result += nativeFindings(layout: layout, directory: directory, root: root, copyRealpaths: copyRealpaths, processes: processes)
        }
        result += heuristicFindings(pathScan: pathScan, recognisedRoots: recognisedRoots)
        result += appManagedFindings()
        return result
    }

    /// The directory holding at least two version-like siblings, one of which is `realpath` or
    /// one of its ancestors.
    public static func heuristicVersionDirectory(containing realpath: URL, fileSystem: CleanupFileSystem) -> URL? {
        var current = realpath
        while current.path != "/", !current.path.isEmpty {
            let parent = current.deletingLastPathComponent()
            if isVersionLike(current.lastPathComponent), parent.path != current.path,
               let siblings = try? fileSystem.contents(of: parent),
               siblings.filter({ isVersionLike($0.url.lastPathComponent) }).count >= 2 {
                return URL(filePath: parent.path, directoryHint: .isDirectory)
            }
            guard parent.path != current.path else { return nil }
            current = parent
        }
        return nil
    }

    static func isVersionLike(_ name: String) -> Bool {
        var scalars = Substring(name).unicodeScalars
        if scalars.first == "v" { scalars = scalars.dropFirst() }
        guard let first = scalars.first, ("0"..."9").contains(first), scalars.contains(".") else { return false }
        return scalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || scalar == "." || scalar == "-" || scalar == "+" || scalar == "_"
        }
    }

    private func nativeFindings(
        layout: CleanupNativeLayout, directory: URL, root: URL, copyRealpaths: [URL], processes: [CleanupProcess]
    ) -> [CleanupFinding] {
        guard let entries = try? fileSystem.contents(of: directory) else { return [] }
        let children = entries.compactMap { entry -> Child? in
            guard let real = try? fileSystem.realpath(entry.url) else { return nil }
            return Child(entry: entry, realpath: real)
        }
        var targets = copyRealpaths.filter { isInside($0, root) }
        let pointer = home.appending(path: layout.pointer, directoryHint: .notDirectory)
        if let pointed = try? fileSystem.realpath(pointer) { targets.insert(pointed, at: 0) }
        let current = targets.lazy.compactMap { target in children.first { isInside(target, $0.realpath, orEqual: true) } }.first
        let source = CleanupSource.nativeVersionDirectory(tool: layout.tool)
        return children.map { child in
            guard let current else {
                return unusedFinding(child, tool: layout.tool, source: source, recognised: false)
            }
            if child.entry.url == current.entry.url {
                return activeFinding(child, tool: layout.tool, source: source)
            }
            let users = CleanupInUseMatcher.processes(
                using: child.realpath, isDirectory: child.entry.kind == .directory, among: processes
            )
            return unusedFinding(
                child, tool: layout.tool, source: source, recognised: true, current: current.name, users: users
            )
        }
    }

    private func heuristicFindings(pathScan: CleanupPathScan, recognisedRoots: [[String]]) -> [CleanupFinding] {
        var activeByDirectory: [String: HeuristicDirectory] = [:]
        var order: [String] = []
        for group in pathScan.groups {
            for copy in group.copies where copy.source == .standalone {
                guard let real = copy.realpath else { continue }
                let components = CleanupPathText.components(of: real.path)
                if recognisedRoots.contains(where: { components.starts(with: $0) }) { continue }
                guard let directory = Self.heuristicVersionDirectory(containing: real, fileSystem: fileSystem) else { continue }
                if activeByDirectory[directory.path] == nil { order.append(directory.path) }
                var entry = activeByDirectory[directory.path] ?? HeuristicDirectory(directory: directory, tool: group.name)
                entry.realpaths.append(real)
                activeByDirectory[directory.path] = entry
            }
        }
        return order.compactMap { activeByDirectory[$0] }.flatMap { found in
            guard let entries = try? fileSystem.contents(of: found.directory) else { return [CleanupFinding]() }
            return entries.filter { Self.isVersionLike($0.url.lastPathComponent) }.map { entry in
                let real = (try? fileSystem.realpath(entry.url)) ?? entry.url
                let child = Child(entry: entry, realpath: real)
                if found.realpaths.contains(where: { isInside($0, real, orEqual: true) }) {
                    return activeFinding(child, tool: found.tool, source: .standalone)
                }
                return unusedFinding(child, tool: found.tool, source: .standalone, recognised: false)
            }
        }
    }

    private func appManagedFindings() -> [CleanupFinding] {
        CleanupKnownLayouts.appManagedLocations.compactMap { location in
            let url = home.appending(path: location.path, directoryHint: .isDirectory)
            guard let entry = try? fileSystem.entry(at: url) else { return nil }
            let source = CleanupSource.appManaged(owner: location.owner)
            let status = CleanupStatus.appManaged
            return CleanupFinding(
                detector: .versionDirectories, tool: location.owner, path: url,
                realpath: try? fileSystem.realpath(url), source: source, version: nil,
                size: try? fileSystem.allocatedSize(of: url), status: status,
                reason: .managedByApp(owner: location.owner), action: .none, risk: .low,
                bucket: CleanupBucketPolicy.bucket(
                    status: status, source: source, relation: .notApplicable, recognisedLayout: true
                ),
                identity: entry.identity
            )
        }
    }

    private func activeFinding(_ child: Child, tool: String, source: CleanupSource) -> CleanupFinding {
        makeFinding(child, tool: tool, source: source, Verdict(
            status: .active, reason: .unknownVersionDirectory, action: .none, risk: .low,
            relation: .notApplicable, recognised: true, sized: false
        ))
    }

    private func unusedFinding(
        _ child: Child, tool: String, source: CleanupSource, recognised: Bool,
        current: String? = nil, users: [CleanupProcess] = []
    ) -> CleanupFinding {
        let status: CleanupStatus = users.isEmpty ? .unused : .inUse(users)
        let trashable = recognised && current != nil
        return makeFinding(child, tool: tool, source: source, Verdict(
            status: status,
            reason: current.map(CleanupReason.olderVersion(current:)) ?? .unknownVersionDirectory,
            action: trashable ? .trash([child.entry.url]) : .instruction(.removeWithCreatingTool),
            risk: users.isEmpty ? .low : .high,
            relation: trashable ? .olderOrSame : .unknown, recognised: recognised, sized: true
        ))
    }

    private func makeFinding(_ child: Child, tool: String, source: CleanupSource, _ verdict: Verdict) -> CleanupFinding {
        CleanupFinding(
            detector: .versionDirectories, tool: tool, path: child.entry.url, realpath: child.realpath,
            source: source, version: child.name,
            size: verdict.sized ? try? fileSystem.allocatedSize(of: child.entry.url) : nil,
            status: verdict.status, reason: verdict.reason, action: verdict.action, risk: verdict.risk,
            bucket: CleanupBucketPolicy.bucket(
                status: verdict.status, source: source, relation: verdict.relation,
                recognisedLayout: verdict.recognised
            ),
            identity: (try? fileSystem.entry(at: child.entry.url))?.identity ?? child.entry.identity
        )
    }

    private func isInside(_ path: URL, _ root: URL, orEqual: Bool = false) -> Bool {
        isInside(path, CleanupPathText.components(of: root.path), orEqual: orEqual)
    }

    private func isInside(_ path: URL, _ root: [String], orEqual: Bool = false) -> Bool {
        let components = CleanupPathText.components(of: path.path)
        guard !root.isEmpty, components.starts(with: root) else { return false }
        return orEqual || components.count > root.count
    }
}
