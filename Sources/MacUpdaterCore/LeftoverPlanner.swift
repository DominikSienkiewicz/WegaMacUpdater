import Foundation

/// Decides which items in the user's home folder are offered for the Trash after apps are
/// uninstalled, and which of them are ticked by default.
///
/// The disk is only read, through `CleanupFileSystem`: `lstat`s and directory listings. Every
/// path passes `LeftoverPathRules.isOfferable` before it is read, and again after a wildcard is
/// expanded. A path is skipped, never the plan, when any folder between the home folder and
/// the item is not a real directory (a symlink, missing, or unreadable).
public enum LeftoverPlanner {
    /// - Parameters:
    ///   - targets: the apps whose leftovers are planned; the groups follow this order.
    ///   - alsoRemoved: apps removed in the same run whose leftovers are not planned (Homebrew-managed).
    ///   - others: the installed apps that stay.
    ///   - home: the user's home folder; neither it nor anything above it is checked.
    /// - Returns: one group per target that has at least one item. Each path appears once, in
    ///   the group of the first target that plans it.
    public static func plan(
        targets: [LeftoverApp],
        alsoRemoved: [LeftoverApp],
        others: [LeftoverApp],
        home: URL,
        fileSystem: any CleanupFileSystem
    ) -> [LeftoverPlanGroup] {
        let homeFolder = HomeFolder(home: home, fileSystem: fileSystem)
        var plannedKeys: Set<String> = []
        return targets.compactMap { target in
            let items = findings(for: target, in: homeFolder)
                .filter { plannedKeys.insert($0.key).inserted }
                .map(\.item)
            return items.isEmpty ? nil : LeftoverPlanGroup(appID: target.id, items: items)
        }
    }

    /// The target's existing items, one per path, in zap-list, bundle-id and then app-name order.
    private static func findings(for target: LeftoverApp, in homeFolder: HomeFolder) -> [Finding] {
        let isStrongZap = target.cask?.isStrong(forBundleIdentifier: target.bundleIdentifier) == true
        let candidates = LeftoverCandidates.zap(for: target).map { ($0, isStrongZap ? Precedence.strongZap : .weakZap) }
            + LeftoverCandidates.bundleIdentifier(for: target).map { ($0, Precedence.bundleIdentifier) }
        var findings: [Finding] = []
        var indexByKey: [String: Int] = [:]
        func record(_ paths: [ExistingPath], _ candidate: LeftoverCandidates.Candidate, _ precedence: Precedence) {
            for path in paths {
                let finding = Finding(path: path, candidate: candidate, precedence: precedence)
                if let index = indexByKey[finding.key] {
                    findings[index].absorb(finding)
                } else {
                    indexByKey[finding.key] = findings.count
                    findings.append(finding)
                }
            }
        }
        for (candidate, precedence) in candidates {
            record(homeFolder.existingPaths(candidate.components), candidate, precedence)
        }
        let names = LeftoverCandidates.names(for: target)
        for parent in LeftoverCandidates.nameParents {
            for name in names {
                let candidate = LeftoverCandidates.nameCandidate(parent: parent, name: name)
                record(homeFolder.existingPaths(named: name, in: parent), candidate, .name)
            }
        }
        return findings
    }
}

/// Which source names an item that several sources found.
private enum Precedence: Int, Comparable {
    case name, weakZap, bundleIdentifier, strongZap

    static func < (lhs: Precedence, rhs: Precedence) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One existing path a target's sources found, merged across the sources that found it.
private struct Finding {
    let key: String
    private(set) var url: URL
    private(set) var source: LeftoverItem.Source
    private(set) var precedence: Precedence
    private(set) var probableReason: LeftoverItem.ProbableReason?

    init(path: ExistingPath, candidate: LeftoverCandidates.Candidate, precedence: Precedence) {
        key = LeftoverPathRules.key(path.components)
        url = path.url
        source = candidate.source
        self.precedence = precedence
        probableReason = candidate.probableReason
    }

    var item: LeftoverItem { LeftoverItem(url: url, source: source, probableReason: probableReason) }

    /// The higher-precedence source names the item; it stays probable only if every source
    /// that found it found it probable.
    mutating func absorb(_ other: Finding) {
        let isProbableForBoth = probableReason != nil && other.probableReason != nil
        if other.precedence > precedence {
            url = other.url
            source = other.source
            precedence = other.precedence
            probableReason = other.probableReason
        }
        if !isProbableForBoth { probableReason = nil }
    }
}

private struct ExistingPath {
    let components: [String]
    let url: URL
}

/// The planner's read-only view of the home folder. It lists each folder at most once.
private final class HomeFolder {
    private let home: URL
    private let fileSystem: any CleanupFileSystem
    private var listings: [String: [String]] = [:]

    init(home: URL, fileSystem: any CleanupFileSystem) {
        self.home = home
        self.fileSystem = fileSystem
    }

    /// The offerable items `pattern` names that exist: the path itself or, when its last
    /// component is a wildcard, each matching name in its folder (with its on-disk spelling).
    func existingPaths(_ pattern: [String]) -> [ExistingPath] {
        guard LeftoverPathRules.isOfferable(pattern), let last = pattern.last else { return [] }
        let folder = Array(pattern.dropLast())
        guard hasRealFolders(folder) else { return [] }
        let names = LeftoverPathRules.hasWildcard(last)
            ? listing(of: folder).filter { LeftoverPathRules.matches(pattern: last, name: $0) }
            : [last]
        return names.compactMap { existingPath(folder: folder, name: $0) }
    }

    /// The offerable entries of `folder` whose name equals `name` ignoring case and Unicode
    /// normalisation, with their on-disk spelling. `name` is literal, never a pattern.
    func existingPaths(named name: String, in folder: [String]) -> [ExistingPath] {
        guard hasRealFolders(folder) else { return [] }
        return listing(of: folder)
            .filter { name.compare($0, options: .caseInsensitive) == .orderedSame }
            .compactMap { existingPath(folder: folder, name: $0) }
    }

    private func existingPath(folder: [String], name: String) -> ExistingPath? {
        let components = folder + [name]
        guard LeftoverPathRules.isOfferable(components),
              let entry = try? fileSystem.entry(at: lookupURL(components)) else { return nil }
        let hint: URL.DirectoryHint = entry.kind == .directory ? .isDirectory : .notDirectory
        return ExistingPath(components: components, url: lookupURL(folder).appending(component: name, directoryHint: hint))
    }

    /// Whether every folder from just below the home folder down to `folder` is a directory.
    private func hasRealFolders(_ folder: [String]) -> Bool {
        folder.indices.allSatisfy { depth in
            (try? fileSystem.entry(at: lookupURL(folder[...depth])))?.kind == .directory
        }
    }

    /// The entry names of `folder`; none when it cannot be listed.
    private func listing(of folder: [String]) -> [String] {
        let key = LeftoverPathRules.key(folder)
        if let cached = listings[key] { return cached }
        let names = (try? fileSystem.contents(of: lookupURL(folder)))?.map(\.url.lastPathComponent) ?? []
        listings[key] = names
        return names
    }

    /// No trailing slash, so `lstat` never follows a link in the last component.
    private func lookupURL(_ components: some Sequence<String>) -> URL {
        components.reduce(home) { $0.appending(component: $1, directoryHint: .notDirectory) }
    }
}
