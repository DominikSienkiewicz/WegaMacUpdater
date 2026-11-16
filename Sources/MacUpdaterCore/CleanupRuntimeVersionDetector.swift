import Foundation

/// D5: every runtime a version manager installed, checked against what the user's projects and
/// the managers' own defaults require. A runtime nothing requires is only ever offered through its
/// manager's uninstall command or an instruction, never the Trash, and always needs a decision:
/// projects outside the configured roots may still use it.
public struct CleanupRuntimeVersionDetector: Sendable {
    private let fileSystem: CleanupFileSystem
    private let home: URL
    private let inspector: ProcessInspecting

    public init(fileSystem: CleanupFileSystem, home: URL, inspector: ProcessInspecting) {
        self.fileSystem = fileSystem
        self.home = home
        self.inspector = inspector
    }

    public func findings(projectFiles: [CleanupProjectFile]) -> [CleanupFinding] {
        let inventory = CleanupRuntimeInventory(fileSystem: fileSystem, home: home)
        let installs = inventory.installs().map(locate)
        guard !installs.isEmpty else { return [] }
        let requirements = projectFiles.flatMap(CleanupRequirementParser.requirements(in:)) + inventory.defaults()
        let sources = installs.map { pinningSources(of: $0, among: installs, requirements: requirements) }
        let processes = sources.contains(where: \.isEmpty) ? inspector.userProcesses() : []
        return zip(installs, sources).map { finding(for: $0, pinnedBy: $1, processes: processes) }
    }

    /// An install with the paths a requirement may name it by: as the manager lists it, and its
    /// physical location (nil when it does not resolve).
    private struct Located {
        let install: CleanupRuntimeInstall
        let realpath: URL?
        let roots: [[String]]
    }

    private func locate(_ install: CleanupRuntimeInstall) -> Located {
        let realpath = try? fileSystem.realpath(install.url)
        let roots = ([install.url] + [realpath].compactMap { $0 }).map { CleanupPathText.components(of: $0.path) }
        return Located(install: install, realpath: realpath, roots: roots.filter { !$0.isEmpty })
    }

    // MARK: Requirements

    private func pinningSources(of located: Located, among all: [Located], requirements: [CleanupRequirement]) -> [String] {
        let paths = requirements
            .filter { $0.tool == located.install.tool && pins($0.spec, located, among: all) }
            .map(\.source.path)
        return Self.sortedUnique(paths)
    }

    private func pins(_ spec: CleanupVersionSpec, _ located: Located, among all: [Located]) -> Bool {
        let install = located.install
        switch spec {
        case .pin(let pin):
            return CleanupVersionMatcher.pin(pin, matches: install.version)
        case .range(let range):
            let grammar = Self.grammar(for: install.tool)
            guard let satisfied = CleanupVersionMatcher.range(range, isSatisfiedBy: install.version, grammar: grammar) else {
                return Self.isNewest(install, among: all)
            }
            return satisfied && !all.contains { other in
                other.install != install && other.install.tool == install.tool
                    && CleanupVersionMatcher.range(range, isSatisfiedBy: other.install.version, grammar: grammar) == true
            }
        case .path(let path):
            let target = CleanupPathText.components(of: path)
            return located.roots.contains { target.starts(with: $0) }
        case .unresolvable:
            return Self.isNewest(install, among: all)
        }
    }

    private static func grammar(for tool: String) -> CleanupRangeGrammar {
        tool == "python" ? .pep440 : .npm
    }

    /// True when no other install of the same manager and tool is newer. Only versions starting
    /// with a digit are ordered, by `compareVersions(_:_:scheme: .semver)`; the rest (rustup's
    /// `stable-aarch64-apple-darwin`, pyenv's `pypy3.10-7.3.12`, which the tolerant parse would
    /// read as 10) are incomparable, so each counts as newest. The verdict depends on the version
    /// texts alone, never on listing order, and an alias or an unreadable default keeps every
    /// candidate it could mean instead of guessing one.
    private static func isNewest(_ install: CleanupRuntimeInstall, among all: [Located]) -> Bool {
        !all.contains { other in
            other.install.manager == install.manager && other.install.tool == install.tool
                && isNewer(other.install.version, than: install.version)
        }
    }

    private static func isNewer(_ candidate: String, than version: String) -> Bool {
        guard isOrderable(candidate), isOrderable(version) else { return false }
        return compareVersions(candidate, version, scheme: .semver) == .orderedDescending
    }

    private static func isOrderable(_ version: String) -> Bool {
        guard let first = version.unicodeScalars.first else { return false }
        return ("0"..."9").contains(first)
    }

    /// Sorted and de-duplicated by Unicode scalars, the way the kernel compares path text.
    private static func sortedUnique(_ paths: [String]) -> [String] {
        paths.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            .reduce(into: []) { unique, path in
                if unique.last.map({ $0.unicodeScalars.elementsEqual(path.unicodeScalars) }) != true {
                    unique.append(path)
                }
            }
    }

    // MARK: Findings

    /// A required runtime keeps its removal action, but the excluded bucket never shows it.
    private func finding(for located: Located, pinnedBy sources: [String], processes: [CleanupProcess]) -> CleanupFinding {
        let install = located.install
        let status: CleanupStatus
        if sources.isEmpty {
            let users = CleanupInUseMatcher.processes(using: located.realpath ?? install.url, isDirectory: true, among: processes)
            status = users.isEmpty ? .unused : .inUse(users)
        } else {
            status = .pinned(by: sources)
        }
        return CleanupFinding(
            detector: .runtimeVersions, tool: install.tool, path: install.url, realpath: located.realpath,
            source: .versionManager(install.manager), version: install.version,
            size: try? fileSystem.allocatedSize(of: install.url), status: status,
            reason: sources.isEmpty ? .notRequiredByProjects : .requiredByProjects,
            action: install.removal, risk: .medium,
            bucket: CleanupBucketPolicy.bucket(status: status, kind: .runtimeVersion, evidenceComplete: true),
            identity: (try? fileSystem.entry(at: install.url))?.identity
        )
    }
}
