import Foundation

/// The package a path from `brew cleanup --dry-run` belongs to, read from the layouts Homebrew
/// writes. Paths are split on scalars (`CleanupPathText`), and so are the `--` separators in
/// cache file names.
enum CleanupHomebrewPackage {
    enum Kind: Equatable, Sendable {
        case formula, cask, cacheOrLog
    }

    /// A cached bottle manifest is linked as `<n>_bottle_manifest--<v>` beside the bottle itself.
    private static let manifestSuffix = Array("_bottle_manifest".unicodeScalars)

    /// `…/Cellar/<n>/<v>` is a formula's old keg and `…/Caskroom/<t>/<v>` a cask's old version. A
    /// download (`…/Caches/Homebrew/downloads/<hex>--<n>--…`), its link (`…/Caches/Homebrew/<n>--…`,
    /// `…/Caches/Homebrew/Cask/<t>--…`) and a log folder (`…/Logs/Homebrew/<n>`) are a cache or
    /// log. Anything else names no package.
    static func name(of item: URL) -> (kind: Kind, name: String)? {
        let components = CleanupPathText.components(of: item.path)
        guard components.count >= 3 else { return nil }
        let last = components[components.count - 1]
        let parent = components[components.count - 2]
        let grandparent = components[components.count - 3]
        let greatGrandparent = components.count >= 4 ? components[components.count - 4] : ""
        switch (greatGrandparent, grandparent, parent) {
        case (_, "Cellar", _):
            return (.formula, parent)
        case (_, "Caskroom", _):
            return (.cask, parent)
        case (_, "Logs", "Homebrew"):
            return (.cacheOrLog, last)
        case (_, "Caches", "Homebrew"), ("Caches", "Homebrew", "Cask"):
            return cacheOrLog(fields(of: last), nameAt: 0)
        case ("Caches", "Homebrew", "downloads"):
            let parts = fields(of: last)
            guard let hash = parts.first, isHexadecimal(hash) else { return nil }
            return cacheOrLog(parts, nameAt: 1)
        default:
            return nil
        }
    }

    /// The name must be followed by another `--` field, the way Homebrew writes its cache names.
    private static func cacheOrLog(_ fields: [String], nameAt index: Int) -> (kind: Kind, name: String)? {
        guard fields.count > index + 1 else { return nil }
        let name = withoutManifestSuffix(fields[index])
        return name.isEmpty ? nil : (.cacheOrLog, name)
    }

    private static func fields(of fileName: String) -> [String] {
        let scalars = Array(fileName.unicodeScalars)
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == "-", index + 1 < scalars.count, scalars[index + 1] == "-" {
                fields.append(String(field))
                field = String.UnicodeScalarView()
                index += 2
            } else {
                field.append(scalars[index])
                index += 1
            }
        }
        fields.append(String(field))
        return fields
    }

    private static func withoutManifestSuffix(_ field: String) -> String {
        let scalars = Array(field.unicodeScalars)
        guard scalars.count > manifestSuffix.count, Array(scalars.suffix(manifestSuffix.count)) == manifestSuffix else {
            return field
        }
        return String(String.UnicodeScalarView(scalars.dropLast(manifestSuffix.count)))
    }

    private static func isHexadecimal(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// D4: what `brew cleanup --dry-run` and `brew autoremove --dry-run` report, as one finding per
/// package with that package's own command — a global `brew cleanup` or `brew autoremove` is never
/// offered. A package upgraded within the operation journal's retention window keeps its old
/// versions, so the upgrade can still be undone; it becomes eligible when the window ends.
public struct CleanupHomebrewDetector: Sendable {
    private enum Side {
        case formula
        case cask
        /// A cache or log whose name no old keg or cask version in the same dry run shares.
        case unattached

        /// Where the side's package directory can be, in the order it is looked for.
        var roots: [Root] {
            switch self {
            case .formula: [.cellar]
            case .cask: [.caskroom]
            case .unattached: [.cellar, .caskroom]
            }
        }
    }

    private struct GroupKey: Equatable {
        let side: Side
        let name: String
    }

    private struct Group {
        let key: GroupKey
        var items: [(item: CleanupBrewCleanupItem, kind: CleanupHomebrewPackage.Kind)]
    }

    private enum Root: CaseIterable {
        case cellar, caskroom

        var component: String {
            switch self {
            case .cellar: "Cellar"
            case .caskroom: "Caskroom"
            }
        }

        func source(of name: String) -> CleanupSource {
            switch self {
            case .cellar: .homebrewFormula(name: name)
            case .caskroom: .homebrewCask(token: name)
            }
        }

        func directory(of name: String, under prefix: URL) -> URL {
            prefix.appending(component: component, directoryHint: .isDirectory)
                .appending(component: name, directoryHint: .isDirectory)
        }
    }

    /// `<prefix>/Cellar/<n>` or `<prefix>/Caskroom/<t>` of a group, as found on disk.
    private struct Package {
        let directory: URL
        let root: Root
    }

    private enum Answer<Value> {
        case answered(Value)
        case failed
        case homebrewMissing

        var value: Value? {
            if case .answered(let value) = self { return value }
            return nil
        }

        var didFail: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private static let unattributedTool = "Homebrew"
    private static let metadataDirectory = ".metadata"

    private let brew: CleanupBrewQuerying
    private let fileSystem: CleanupFileSystem
    private let inspector: ProcessInspecting
    private let brewPrefix: URL?
    private let now: Date

    public init(brew: CleanupBrewQuerying, fileSystem: CleanupFileSystem, inspector: ProcessInspecting, brewPrefix: URL?, now: Date) {
        self.brew = brew
        self.fileSystem = fileSystem
        self.inspector = inspector
        self.brewPrefix = brewPrefix
        self.now = now
    }

    /// A Mac without Homebrew gets neither findings nor a note. A dry run that fails otherwise
    /// leaves one `dryRunFailed` note and contributes no findings; without the cleanup dry run the
    /// kept versions cannot be told from leftovers, so they are not reported either.
    public func scan() async -> (findings: [CleanupFinding], notes: [CleanupDetectorNote]) {
        guard let brewPrefix else { return ([], []) }
        let cleanup = await answer { try await brew.cleanupDryRun(package: nil) }
        if case .homebrewMissing = cleanup { return ([], []) }
        let autoremove = await answer { try await brew.autoremoveDryRun() }
        if case .homebrewMissing = autoremove { return ([], []) }

        let items = cleanup.value
        let names = autoremove.value ?? []
        let processes = (items ?? []).isEmpty && names.isEmpty ? [] : inspector.userProcesses()
        let uninstalled = Self.uninstalledKegFolders(names)
        var findings = items.map {
            cleanupFindings($0, prefix: brewPrefix, processes: processes, uninstalled: uninstalled)
        } ?? []
        findings += autoremoveFindings(names, prefix: brewPrefix, processes: processes)
        let notes = cleanup.didFail || autoremove.didFail ? [CleanupDetectorNote(detector: .homebrew, kind: .dryRunFailed)] : []
        return (findings, notes)
    }

    /// The newest modification date among a package directory's version directories; a cask's
    /// `.metadata` folder is not a version.
    static func lastInstall(in packageDirectory: URL, fileSystem: CleanupFileSystem) -> Date? {
        versionDirectories(in: packageDirectory, fileSystem: fileSystem).compactMap(\.modificationDate).max()
    }

    private static func versionDirectories(in packageDirectory: URL, fileSystem: CleanupFileSystem) -> [CleanupEntry] {
        let entries = (try? fileSystem.contents(of: packageDirectory)) ?? []
        return entries.filter { entry in
            entry.kind == .directory && CleanupPathText.components(of: entry.url.path).last != metadataDirectory
        }
    }

    private func answer<Value>(_ query: () async throws -> Value) async -> Answer<Value> {
        do {
            return .answered(try await query())
        } catch BrewServiceError.brewNotFound {
            return .homebrewMissing
        } catch {
            return .failed
        }
    }

    /// The keg folders (`Cellar/<short name>`) of the valid autoremove names. `brew uninstall`
    /// removes the old kegs with the formula, so its finding replaces that formula's cleanup group
    /// and kept-version note; one path then has one finding, and finding ids stay unique.
    private static func uninstalledKegFolders(_ names: [String]) -> Set<String> {
        Set(names.filter(CleanupHomebrewNames.isValid).map(shortName))
    }

    private static func shortName(of name: String) -> String {
        CleanupPathText.components(of: name).last ?? name
    }

    private func cleanupFindings(
        _ items: [CleanupBrewCleanupItem], prefix: URL, processes: [CleanupProcess], uninstalled: Set<String>
    ) -> [CleanupFinding] {
        let (groups, unattributed) = Self.groups(of: items)
        var findings: [CleanupFinding] = []
        for group in groups {
            let package = existingPackage(of: group.key, prefix: prefix)
            guard !Self.isUninstalled(group.key, package: package, by: uninstalled) else { continue }
            findings.append(finding(for: group, package: package, processes: processes))
        }
        if let first = unattributed.first {
            findings.append(infoFinding(
                tool: Self.unattributedTool, path: first.path, source: nil, size: Self.knownSize(of: unattributed),
                reason: .homebrewLeftovers(items: unattributed.count)
            ))
        }
        let uninstalledKeys = uninstalled.map { GroupKey(side: .formula, name: $0) }
        return findings + keptVersionFindings(prefix: prefix, named: groups.map(\.key) + uninstalledKeys)
    }

    /// `brew uninstall --formula` leaves a cask of the same name alone, so only the formula side, or
    /// a cache or log whose package directory is the keg folder, is replaced.
    private static func isUninstalled(_ key: GroupKey, package: Package?, by uninstalled: Set<String>) -> Bool {
        guard uninstalled.contains(key.name) else { return false }
        switch key.side {
        case .formula: return true
        case .cask: return false
        case .unattached: return package?.root == .cellar
        }
    }

    /// One group per package, in dry-run order. A formula and a cask of the same name stay apart;
    /// a cache or log joins the formula of its name, else the cask, else stands on its own.
    private static func groups(
        of items: [CleanupBrewCleanupItem]
    ) -> (named: [Group], unattributed: [CleanupBrewCleanupItem]) {
        let parsed = items.map { (item: $0, package: CleanupHomebrewPackage.name(of: $0.path)) }
        let formulas = Set(parsed.compactMap { $0.package?.kind == .formula ? $0.package?.name : nil })
        let casks = Set(parsed.compactMap { $0.package?.kind == .cask ? $0.package?.name : nil })
        var groups: [Group] = []
        var unattributed: [CleanupBrewCleanupItem] = []
        for (item, package) in parsed {
            guard let package else {
                unattributed.append(item)
                continue
            }
            let side: Side = switch package.kind {
            case .formula: .formula
            case .cask: .cask
            case .cacheOrLog: formulas.contains(package.name) ? .formula : casks.contains(package.name) ? .cask : .unattached
            }
            let key = GroupKey(side: side, name: package.name)
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].items.append((item, package.kind))
            } else {
                groups.append(Group(key: key, items: [(item, package.kind)]))
            }
        }
        return (groups, unattributed)
    }

    /// A name `CleanupHomebrewNames` refuses never becomes a path, so it has no package directory.
    private func existingPackage(of key: GroupKey, prefix: URL) -> Package? {
        guard CleanupHomebrewNames.isValid(key.name) else { return nil }
        return key.side.roots.lazy.map { Package(directory: $0.directory(of: key.name, under: prefix), root: $0) }
            .first { (try? fileSystem.entry(at: $0.directory))?.kind == .directory }
    }

    private func finding(for group: Group, package: Package?, processes: [CleanupProcess]) -> CleanupFinding {
        let name = group.key.name
        let path = package?.directory ?? group.items[0].item.path
        let status = status(of: group, package: package, processes: processes)
        let reason: CleanupReason
        if case .recentUpgrade = status { reason = .recentlyUpgraded } else { reason = .homebrewLeftovers(items: group.items.count) }
        return CleanupFinding(
            detector: .homebrew, tool: name, path: path, realpath: try? fileSystem.realpath(path),
            source: package.map { $0.root.source(of: name) } ?? Self.source(of: group.key),
            version: nil, size: Self.knownSize(of: group.items.map(\.item)), status: status, reason: reason,
            action: CleanupHomebrewNames.isValid(name) ? .brew(.cleanup(name)) : .none, risk: .low,
            bucket: CleanupBucketPolicy.bucket(status: status, kind: .homebrewCleanup, evidenceComplete: true),
            identity: (try? fileSystem.entry(at: path))?.identity
        )
    }

    /// The source a group's side implies when its package directory is gone.
    private static func source(of key: GroupKey) -> CleanupSource? {
        switch key.side {
        case .formula: Root.cellar.source(of: key.name)
        case .cask: Root.caskroom.source(of: key.name)
        case .unattached: nil
        }
    }

    /// A recent upgrade wins over use: until the window ends nothing in the package is offered.
    /// Only the old kegs and cask versions are checked for use, never the current version.
    private func status(of group: Group, package: Package?, processes: [CleanupProcess]) -> CleanupStatus {
        if let package, let last = Self.lastInstall(in: package.directory, fileSystem: fileSystem) {
            let eligible = last.addingTimeInterval(UpdateOperationStore.retentionInterval)
            if now < eligible { return .recentUpgrade(until: eligible) }
        }
        var users: [CleanupProcess] = []
        for entry in group.items where entry.kind != .cacheOrLog {
            guard let real = try? fileSystem.realpath(entry.item.path) else { continue }
            for user in CleanupInUseMatcher.processes(using: real, isDirectory: true, among: processes)
            where !users.contains(where: { $0.pid == user.pid }) {
                users.append(user)
            }
        }
        return users.isEmpty ? .unused : .inUse(users)
    }

    /// One finding per keg folder: a tap-qualified name and its short name are the same formula.
    private func autoremoveFindings(_ names: [String], prefix: URL, processes: [CleanupProcess]) -> [CleanupFinding] {
        var seen: Set<String> = []
        return names.compactMap { name in
            let path = Self.kegFolder(of: name, under: prefix)
            guard seen.insert(path.path).inserted else { return nil }
            return autoremoveFinding(name, path: path, processes: processes)
        }
    }

    /// `brew autoremove` names a formula by its full name; its keg folder is `Cellar/<short name>`.
    /// A name `CleanupHomebrewNames` refuses stays one whole path component, so it never names a
    /// valid formula's keg folder.
    private static func kegFolder(of name: String, under prefix: URL) -> URL {
        Root.cellar.directory(of: CleanupHomebrewNames.isValid(name) ? shortName(of: name) : name, under: prefix)
    }

    /// A name `CleanupHomebrewNames` refuses is reported without an action and never read from disk.
    private func autoremoveFinding(_ name: String, path: URL, processes: [CleanupProcess]) -> CleanupFinding {
        let isValid = CleanupHomebrewNames.isValid(name)
        let realpath = isValid ? (try? fileSystem.realpath(path)) : nil
        let users = realpath.map { CleanupInUseMatcher.processes(using: $0, isDirectory: true, among: processes) } ?? []
        let status: CleanupStatus = users.isEmpty ? .unused : .inUse(users)
        return CleanupFinding(
            detector: .homebrew, tool: name, path: path, realpath: realpath, source: .homebrewFormula(name: name),
            version: nil, size: isValid ? (try? fileSystem.allocatedSize(of: path)) : nil, status: status,
            reason: .installedOnlyAsDependency, action: isValid ? .brew(.uninstallFormula(name)) : .none, risk: .medium,
            bucket: CleanupBucketPolicy.bucket(status: status, kind: .homebrewAutoremove, evidenceComplete: true),
            identity: isValid ? (try? fileSystem.entry(at: path))?.identity : nil
        )
    }

    /// Package directories holding two or more versions that no cleanup group names: a pinned
    /// formula, or a cask that updates itself.
    private func keptVersionFindings(prefix: URL, named keys: [GroupKey]) -> [CleanupFinding] {
        Root.allCases.flatMap { root -> [CleanupFinding] in
            let directory = prefix.appending(component: root.component, directoryHint: .isDirectory)
            let packages = (try? fileSystem.contents(of: directory)) ?? []
            return packages.compactMap { package -> CleanupFinding? in
                guard package.kind == .directory, let name = CleanupPathText.components(of: package.url.path).last,
                      !keys.contains(where: { $0.name == name && $0.side.roots.contains(root) }) else { return nil }
                let count = Self.versionDirectories(in: package.url, fileSystem: fileSystem).count
                guard count >= 2 else { return nil }
                return infoFinding(
                    tool: name, path: package.url, source: root.source(of: name), size: nil,
                    reason: .homebrewKeptVersions(count: count)
                )
            }
        }
    }

    private func infoFinding(
        tool: String, path: URL, source: CleanupSource?, size: Int64?, reason: CleanupReason
    ) -> CleanupFinding {
        let status = CleanupStatus.info
        return CleanupFinding(
            detector: .homebrew, tool: tool, path: path, realpath: try? fileSystem.realpath(path), source: source,
            version: nil, size: size, status: status, reason: reason, action: .none, risk: .low,
            bucket: CleanupBucketPolicy.bucket(status: status, source: source, relation: .notApplicable, recognisedLayout: true),
            identity: (try? fileSystem.entry(at: path))?.identity
        )
    }

    /// The sum of the sizes Homebrew printed, saturating instead of trapping; nil when none was.
    private static func knownSize(of items: [CleanupBrewCleanupItem]) -> Int64? {
        let sizes = items.compactMap(\.size)
        guard !sizes.isEmpty else { return nil }
        return sizes.reduce(Int64(0)) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(size)
            return overflow ? .max : sum
        }
    }
}
