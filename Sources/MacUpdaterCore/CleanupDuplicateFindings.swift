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
        let brewAnswered: Bool
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
        let (dependents, notes) = await dependentsByFormula(in: scan)
        let context = Context(processes: inspector.userProcesses(), dependents: dependents, brewAnswered: notes.isEmpty)
        let findings = scan.groups.flatMap { group in
            group.copies.map { finding(for: $0, in: group, context: context) }
        }
        return (findings, notes)
    }

    private func dependentsByFormula(in scan: CleanupPathScan) async -> ([String: [String]], [CleanupDetectorNote]) {
        var names: [String] = []
        for copy in scan.groups.flatMap(\.copies) where copy.role == .shadowed {
            if case .homebrewFormula(let name) = copy.source, !names.contains(name) { names.append(name) }
        }
        var result: [String: [String]] = [:]
        for name in names {
            do {
                let uses = try await brew.usesInstalled(formula: name)
                if !uses.isEmpty { result[name] = uses }
            } catch BrewServiceError.brewNotFound {
                return ([:], [CleanupDetectorNote(detector: .homebrew, kind: .homebrewUnavailable)])
            } catch {
                return ([:], [CleanupDetectorNote(detector: .homebrew, kind: .failed)])
            }
        }
        return (result, [])
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
            bucket: CleanupBucketPolicy.bucket(
                status: status, source: copy.source, relation: relation, recognisedLayout: true
            ),
            identity: copy.identity
        )
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
        let action = removalAction(for: copy, brewAnswered: context.brewAnswered)
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

    private func removalAction(for copy: CleanupCopy, brewAnswered: Bool) -> CleanupAction {
        switch copy.source {
        case .homebrewFormula(let name): return brewAnswered ? .brew(.uninstallFormula(name)) : .none
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
            return .command("uv tool uninstall \(components[uvRoot.count + 1])")
        }
        if components.starts(with: uvRoot + ["python"]), let version = copy.version {
            return .command("uv python uninstall \(version)")
        }
        return .instruction(.removeWithCreatingTool)
    }

    private func packageManagerAction(_ manager: CleanupPackageManager, copy: CleanupCopy) -> CleanupAction {
        let components = copy.realpath.map { CleanupPathText.components(of: $0.path) } ?? []
        switch manager {
        case .npm:
            guard let package = npmPackage(in: components) else { return .instruction(.removeWithCreatingTool) }
            return .command("npm uninstall -g \(package)")
        case .pipx:
            guard let index = components.firstIndex(of: "venvs"), index + 1 < components.count else {
                return .instruction(.removeWithCreatingTool)
            }
            return .command("pipx uninstall \(components[index + 1])")
        case .cargo:
            return .command("cargo uninstall \(copy.path.lastPathComponent)")
        case .pnpm, .bun, .go:
            return .instruction(.removeWithCreatingTool)
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
