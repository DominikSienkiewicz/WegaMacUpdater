import Foundation

public protocol CleanupBrewQuerying: Sendable {
    func usesInstalled(formula: String) async throws -> [String]
    /// `brew cleanup --dry-run [-- <package>]`: what Homebrew would delete, without deleting it.
    func cleanupDryRun(package: String?) async throws -> [CleanupBrewCleanupItem]
    /// `brew autoremove --dry-run`: the formulae Homebrew would uninstall as unneeded.
    func autoremoveDryRun() async throws -> [String]
}

/// One path `brew cleanup --dry-run` would remove, with the size Homebrew printed for it.
public struct CleanupBrewCleanupItem: Equatable, Sendable {
    public let path: URL
    public let size: Int64?

    public init(path: URL, size: Int64?) {
        self.path = path
        self.size = size
    }
}

extension BrewService: CleanupBrewQuerying {}

public struct CleanupDetectorNote: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case homebrewUnavailable, failed, dryRunFailed, noProjectRoots, projectWalkTruncated, unrecognisedIDEInstall
        case tccUnreadable, tccUnsupportedSchema, tccMapEmpty
    }

    public let detector: CleanupDetectorID
    public let kind: Kind

    public init(detector: CleanupDetectorID, kind: Kind) {
        self.detector = detector
        self.kind = kind
    }
}

/// Turns the D1 groups into findings. In a tool group with at least two candidate copies (the
/// `PATH`-active one and the shadowed ones) every candidate carries the removal that matches the tool
/// that installed it, the installed formulae that depend on it and the processes using it;
/// `CleanupKeepChoice` then decides which copy stays and what the others offer. A copy whose only
/// companions are system copies or broken links offers no choice, and a broken link gets a
/// copyable `unlink`.
public struct CleanupDuplicateFindings: Sendable {
    private struct Context {
        let processes: [CleanupProcess]
        let dependents: [String: [String]]
        let uncheckedFormulas: Set<String>
    }

    private let brew: CleanupBrewQuerying
    private let inspector: ProcessInspecting
    private let fileSystem: CleanupFileSystem
    private let brewPrefix: URL?
    private let home: URL
    private let pathIsApproximate: Bool

    public init(
        brew: CleanupBrewQuerying, inspector: ProcessInspecting, fileSystem: CleanupFileSystem,
        brewPrefix: URL?, home: URL, pathIsApproximate: Bool
    ) {
        self.brew = brew
        self.inspector = inspector
        self.fileSystem = fileSystem
        self.brewPrefix = brewPrefix
        self.home = home
        self.pathIsApproximate = pathIsApproximate
    }

    /// The findings come out resolved with no remembered choice: the `PATH`-active copy is kept,
    /// or no copy at all while `PATH` is approximate.
    public func build(_ scan: CleanupPathScan) async -> (findings: [CleanupFinding], notes: [CleanupDetectorNote]) {
        let lookup = await dependentsByFormula(in: scan)
        let context = Context(processes: inspector.userProcesses(), dependents: lookup.dependents, uncheckedFormulas: lookup.unchecked)
        let findings = scan.groups.flatMap { group in
            let offersChoice = Self.candidates(in: group).count >= 2
            return group.copies.map { finding(for: $0, in: group, offersChoice: offersChoice, context: context) }
        }
        return (CleanupKeepChoice.resolve(findings, choices: [:], pathIsApproximate: pathIsApproximate), lookup.notes)
    }

    private struct Lookup {
        var dependents: [String: [String]] = [:]
        var unchecked: Set<String> = []
        var notes: [CleanupDetectorNote] = []
    }

    private static func candidates(in group: CleanupToolGroup) -> [CleanupCopy] {
        group.copies.filter { $0.role == .active || $0.role == .shadowed }
    }

    /// One query per distinct formula among the candidates of the groups that offer a choice, the
    /// active copy included. After the first failure the remaining formulas stay unchecked, while
    /// what was already learned is kept.
    private func dependentsByFormula(in scan: CleanupPathScan) async -> Lookup {
        var names: [String] = []
        for group in scan.groups {
            let candidates = Self.candidates(in: group)
            guard candidates.count >= 2 else { continue }
            for copy in candidates {
                if case .homebrewFormula(let name) = copy.source, !names.contains(name) { names.append(name) }
            }
        }
        var lookup = Lookup()
        for (offset, name) in names.enumerated() {
            do {
                let uses = try await brew.usesInstalled(formula: name)
                if !uses.isEmpty { lookup.dependents[name] = uses }
            } catch {
                let kind: CleanupDetectorNote.Kind
                if case BrewServiceError.brewNotFound = error { kind = .homebrewUnavailable } else { kind = .failed }
                lookup.notes = [CleanupDetectorNote(detector: .homebrew, kind: kind)]
                lookup.unchecked = Set(names[offset...])
                return lookup
            }
        }
        return lookup
    }

    private func finding(
        for copy: CleanupCopy, in group: CleanupToolGroup, offersChoice: Bool, context: Context
    ) -> CleanupFinding {
        func make(_ status: CleanupStatus, _ reason: CleanupReason, _ action: CleanupAction, candidate: CleanupCandidate? = nil) -> CleanupFinding {
            let risk: CleanupRisk
            if case .inUse = status { risk = .high } else { risk = .low }
            return CleanupFinding(
                detector: .pathDuplicates, tool: group.name, path: copy.path, realpath: copy.realpath,
                source: copy.source, version: copy.version, size: nil, status: status, reason: reason,
                action: action, risk: risk, bucket: .excluded, identity: copy.identity, candidate: candidate
            )
        }
        switch copy.role {
        case .expected: return make(.expected, .systemCopy, .none)
        case .brokenLink: return make(.brokenLink, .brokenLink, unlinkAction(for: copy.path))
        case .active where !offersChoice: return make(.active, .currentVersion, .none)
        case .active, .shadowed: break
        }
        let candidate = candidate(for: copy, context: context)
        return make(status(of: copy, candidate), .noCopyKept, .none, candidate: candidate)
    }

    private func candidate(for copy: CleanupCopy, context: Context) -> CleanupCandidate {
        var dependents: [String] = []
        if case .homebrewFormula(let name) = copy.source { dependents = context.dependents[name] ?? [] }
        let processes = copy.realpath.map {
            CleanupInUseMatcher.processes(using: $0, isDirectory: false, among: context.processes)
        } ?? []
        let removal = removalAction(for: copy, context: context)
        return CleanupCandidate(
            pathRole: copy.role, removal: removal, removalSize: size(of: copy, action: removal),
            dependents: dependents, processes: processes
        )
    }

    /// Statuses are `PATH` facts (B5): the active copy stays `active` whatever blocks its removal.
    private func status(of copy: CleanupCopy, _ candidate: CleanupCandidate) -> CleanupStatus {
        if copy.role == .active { return .active }
        if !candidate.dependents.isEmpty { return .dependency(candidate.dependents) }
        if !candidate.processes.isEmpty { return .inUse(candidate.processes) }
        return .shadowed
    }

    /// `unlink` removes one directory entry and cannot recurse; outside the home the link is
    /// usually root-owned, so the command carries `sudo`. Wega never runs it.
    private func unlinkAction(for link: URL) -> CleanupAction {
        let path = link.path
        guard Self.isSafeCommandPath(path) else { return .none }
        let isInHome = CleanupPathText.components(of: path).starts(with: CleanupPathText.components(of: home.path))
        return .command(isInHome ? "unlink \(path)" : "sudo unlink \(path)")
    }

    /// The removal that fits the tool that installed the copy, whichever copy is kept instead.
    private func removalAction(for copy: CleanupCopy, context: Context) -> CleanupAction {
        switch copy.source {
        case .homebrewFormula(let name):
            return context.uncheckedFormulas.contains(name) ? .none : .brew(.uninstallFormula(name))
        case .homebrewCask(let token): return .brew(.uninstallCask(token))
        case .appBundle(let name): return appRemoval(for: copy, named: name)
        case .appManaged, .system, .nativeVersionDirectory: return .none
        case .standalone: return standaloneAction(for: copy)
        case .versionManager(let manager): return versionManagerAction(manager, copy: copy)
        case .packageManager(let manager): return packageManagerAction(manager, copy: copy)
        }
    }

    private func appRemoval(for copy: CleanupCopy, named name: String) -> CleanupAction {
        guard let real = copy.realpath, let bundle = CleanupKeepChoice.enclosingAppBundle(of: real) else {
            return .instruction(.removeAppLinkWithAdminRights(link: copy.path.path))
        }
        return .uninstallApp(name: name, bundle: bundle)
    }

    private func standaloneAction(for copy: CleanupCopy) -> CleanupAction {
        if let real = copy.realpath,
           CleanupVersionDirectoryDetector.heuristicVersionDirectory(containing: real, fileSystem: fileSystem) != nil {
            return .instruction(.removeWithCreatingTool)
        }
        return .trash([copy.path])
    }

    private func versionManagerAction(_ manager: CleanupVersionManager, copy: CleanupCopy) -> CleanupAction {
        guard manager == .uv, let real = copy.realpath else { return .instruction(.removeWithCreatingTool) }
        let components = CleanupPathText.components(of: real.path)
        let uvRoot = CleanupPathText.components(of: home.path) + [".local", "share", "uv"]
        if components.starts(with: uvRoot + ["tools"]), components.count > uvRoot.count + 1 {
            let tool = components[uvRoot.count + 1]
            return Self.isSafeToolToken(tool) ? .command("uv tool uninstall \(tool)") : .instruction(.removeWithCreatingTool)
        }
        if components.starts(with: uvRoot + ["python"]), let version = copy.version, Self.isSafeToolToken(version) {
            return .command("uv python uninstall \(version)")
        }
        return .instruction(.removeWithCreatingTool)
    }

    private func packageManagerAction(_ manager: CleanupPackageManager, copy: CleanupCopy) -> CleanupAction {
        let components = copy.realpath.map { CleanupPathText.components(of: $0.path) } ?? []
        switch manager {
        case .npm:
            guard let global = npmGlobal(in: components), Self.isSafeToolToken(global.package, allowingScope: true),
                  Self.isSafeCommandPath(global.prefix) else {
                return .instruction(.removeWithCreatingTool)
            }
            return .command("npm uninstall -g --prefix \(global.prefix) \(global.package)")
        case .pipx:
            guard let index = components.firstIndex(of: "venvs"), index + 1 < components.count,
                  Self.isSafeToolToken(components[index + 1]) else {
                return .instruction(.removeWithCreatingTool)
            }
            return .command("pipx uninstall \(components[index + 1])")
        case .cargo, .pnpm, .bun, .go:
            return .instruction(.removeWithCreatingTool)
        }
    }

    /// Names that come from directory names end up in a command the user pastes into a terminal, so
    /// only `[A-Za-z0-9._+@-]` is allowed (plus one `/` in a scoped npm name); no leading `-`, no `.`/`..`.
    static func isSafeToolToken(_ token: String, allowingScope: Bool = false) -> Bool {
        let parts = token.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || (allowingScope && parts.count == 2 && parts[0].first == "@") else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first != "-", part.count > 0 else { return false }
            let text = String(String.UnicodeScalarView(part))
            return text != "." && text != ".." && part.allSatisfy(isCommandScalar)
        }
    }

    /// A directory that ends up in a pasted command: absolute, only `[A-Za-z0-9._+@/-]`, and no
    /// component that is `.` or `..` or starts with `-`.
    static func isSafeCommandPath(_ path: String) -> Bool {
        guard CleanupPathText.isAbsolute(path), path.unicodeScalars.allSatisfy({ $0 == "/" || isCommandScalar($0) }) else {
            return false
        }
        return CleanupPathText.components(of: path).allSatisfy { component in
            component != "." && component != ".." && component.unicodeScalars.first != "-"
        }
    }

    private static func isCommandScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
            || ".+@-_".unicodeScalars.contains(scalar)
    }

    /// The npm prefix that owns the copy (the directory holding its `lib/node_modules`) and the
    /// package name, read from the copy's real path.
    private func npmGlobal(in components: [String]) -> (prefix: String, package: String)? {
        guard let index = components.indices.dropFirst().first(where: {
            components[$0] == "node_modules" && components[$0 - 1] == "lib"
        }), index + 1 < components.count else { return nil }
        let prefix = "/" + components[..<(index - 1)].joined(separator: "/")
        let name = components[index + 1]
        guard name.unicodeScalars.first == "@" else { return (prefix, name) }
        return index + 2 < components.count ? (prefix, "\(name)/\(components[index + 2])") : nil
    }

    private func size(of copy: CleanupCopy, action: CleanupAction) -> Int64? {
        switch action {
        case .trash(let targets):
            return targets.first.flatMap { try? fileSystem.allocatedSize(of: $0) }
        case .brew:
            return packageDirectory(of: copy).flatMap { try? fileSystem.allocatedSize(of: $0) }
        default:
            return nil
        }
    }

    /// `<prefix>/Cellar/<name>/<version>` or `<prefix>/Caskroom/<token>/<version>`.
    private func packageDirectory(of copy: CleanupCopy) -> URL? {
        guard let prefix = brewPrefix, let real = copy.realpath else { return nil }
        let root = CleanupPathText.components(of: prefix.path)
        let components = CleanupPathText.components(of: real.path)
        guard components.starts(with: root), components.count >= root.count + 3 else { return nil }
        let kind = components[root.count]
        guard kind == "Cellar" || kind == "Caskroom" else { return nil }
        let path = "/" + components.prefix(root.count + 3).joined(separator: "/")
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
