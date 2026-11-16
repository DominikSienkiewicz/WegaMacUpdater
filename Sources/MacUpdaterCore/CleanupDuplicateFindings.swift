import Foundation

public protocol CleanupBrewQuerying: Sendable {
    func usesInstalled(formula: String) async throws -> [String]
}

extension BrewService: CleanupBrewQuerying {}

public struct CleanupDetectorNote: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case homebrewUnavailable, failed
    }

    public let detector: CleanupDetectorID
    public let kind: Kind

    public init(detector: CleanupDetectorID, kind: Kind) {
        self.detector = detector
        self.kind = kind
    }
}

/// Turns the D1 groups into findings. Each shadowed copy gets the removal that matches the tool that
/// installed it; a Homebrew formula another installed formula depends on is never offered for removal.
public struct CleanupDuplicateFindings: Sendable {
    private struct Context {
        let processes: [CleanupProcess]
        let dependents: [String: [String]]
        let uncheckedFormulas: Set<String>
    }

    private struct Verdict {
        let status: CleanupStatus
        let reason: CleanupReason
        let action: CleanupAction
    }

    private let brew: CleanupBrewQuerying
    private let inspector: ProcessInspecting
    private let fileSystem: CleanupFileSystem
    private let brewPrefix: URL?
    private let home: URL

    public init(
        brew: CleanupBrewQuerying, inspector: ProcessInspecting, fileSystem: CleanupFileSystem,
        brewPrefix: URL?, home: URL
    ) {
        self.brew = brew
        self.inspector = inspector
        self.fileSystem = fileSystem
        self.brewPrefix = brewPrefix
        self.home = home
    }

    public func build(_ scan: CleanupPathScan) async -> (findings: [CleanupFinding], notes: [CleanupDetectorNote]) {
        let lookup = await dependentsByFormula(in: scan)
        let notes = lookup.notes
        let context = Context(processes: inspector.userProcesses(), dependents: lookup.dependents, uncheckedFormulas: lookup.unchecked)
        let findings = scan.groups.flatMap { group in
            group.copies.map { finding(for: $0, in: group, context: context) }
        }
        return (findings, notes)
    }

    private struct Lookup {
        var dependents: [String: [String]] = [:]
        var unchecked: Set<String> = []
        var notes: [CleanupDetectorNote] = []
    }

    /// One query per distinct shadowed formula. After the first failure the remaining formulas stay
    /// unchecked, while what was already learned is kept.
    private func dependentsByFormula(in scan: CleanupPathScan) async -> Lookup {
        var names: [String] = []
        for copy in scan.groups.flatMap(\.copies) where copy.role == .shadowed {
            if case .homebrewFormula(let name) = copy.source, !names.contains(name) { names.append(name) }
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

    private func finding(for copy: CleanupCopy, in group: CleanupToolGroup, context: Context) -> CleanupFinding {
        let active = group.copies.first { $0.role == .active }
        let verdict = classify(copy, active: active, context: context)
        let (status, reason, action) = (verdict.status, verdict.reason, verdict.action)
        let relation = copy.role == .shadowed ? relation(of: copy, to: active) : .notApplicable
        let risk: CleanupRisk
        if case .inUse = status { risk = .high } else { risk = .low }
        return CleanupFinding(
            detector: .pathDuplicates, tool: group.name, path: copy.path, realpath: copy.realpath,
            source: copy.source, version: copy.version, size: size(of: copy, action: action),
            status: status, reason: reason, action: action, risk: risk,
            bucket: bucket(status: status, source: copy.source, relation: relation, action: action),
            identity: copy.identity
        )
    }

    /// A copy Wega cannot remove never counts towards the safe total.
    private func bucket(
        status: CleanupStatus, source: CleanupSource, relation: CleanupVersionRelation, action: CleanupAction
    ) -> CleanupBucket {
        let bucket = CleanupBucketPolicy.bucket(status: status, source: source, relation: relation, recognisedLayout: true)
        return bucket == .safe && action == .none ? .needsDecision : bucket
    }

    private func classify(
        _ copy: CleanupCopy, active: CleanupCopy?, context: Context
    ) -> Verdict {
        switch copy.role {
        case .active: return Verdict(status: .active, reason: .currentVersion, action: .none)
        case .expected: return Verdict(status: .expected, reason: .systemCopy, action: .none)
        case .brokenLink: return Verdict(status: .brokenLink, reason: .brokenLink, action: .none)
        case .shadowed: break
        }
        let reason = CleanupReason.shadowedBy(path: (active?.path ?? copy.path).path)
        if case .homebrewFormula(let name) = copy.source, let dependents = context.dependents[name] {
            return Verdict(status: .dependency(dependents), reason: .requiredBy(dependents), action: .none)
        }
        let action = removalAction(for: copy, context: context)
        if let real = copy.realpath {
            let using = CleanupInUseMatcher.processes(using: real, isDirectory: false, among: context.processes)
            if !using.isEmpty { return Verdict(status: .inUse(using), reason: reason, action: action) }
        }
        return Verdict(status: .shadowed, reason: reason, action: action)
    }

    private func relation(of copy: CleanupCopy, to active: CleanupCopy?) -> CleanupVersionRelation {
        guard let version = copy.version, let current = active?.version else { return .unknown }
        switch compareVersions(version, current, scheme: .semver) {
        case .orderedAscending, .orderedSame: return .olderOrSame
        case .orderedDescending: return .newer
        case .unknown: return .unknown
        }
    }

    private func removalAction(for copy: CleanupCopy, context: Context) -> CleanupAction {
        switch copy.source {
        case .homebrewFormula(let name):
            return context.uncheckedFormulas.contains(name) ? .none : .brew(.uninstallFormula(name))
        case .homebrewCask(let token): return .brew(.uninstallCask(token))
        case .appBundle: return .instruction(.removeAppLinkWithAdminRights(link: copy.path.path))
        case .appManaged, .system, .nativeVersionDirectory: return .none
        case .standalone: return standaloneAction(for: copy)
        case .versionManager(let manager): return versionManagerAction(manager, copy: copy)
        case .packageManager(let manager): return packageManagerAction(manager, copy: copy)
        }
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
            guard let package = npmPackage(in: components), Self.isSafeToolToken(package, allowingScope: true) else { return .instruction(.removeWithCreatingTool) }
            return .command("npm uninstall -g \(package)")
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
            return text != "." && text != ".." && part.allSatisfy { scalar in
                ("0"..."9").contains(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                    || ".+@-_".unicodeScalars.contains(scalar)
            }
        }
    }

    private func npmPackage(in components: [String]) -> String? {
        guard let index = components.indices.dropFirst().first(where: {
            components[$0] == "node_modules" && components[$0 - 1] == "lib"
        }), index + 1 < components.count else { return nil }
        let name = components[index + 1]
        guard name.unicodeScalars.first == "@" else { return name }
        return index + 2 < components.count ? "\(name)/\(components[index + 2])" : nil
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
