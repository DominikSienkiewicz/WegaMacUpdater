import Foundation

/// Uninstalls one Homebrew package for Cleanup; never with `--zap` or `--force`.
public protocol CleanupBrewRemoving: Sendable {
    func uninstallCask(token: String) async throws
    func uninstallFormula(name: String) async throws
    func cleanupPackage(name: String) async throws
}

/// `BrewService` cannot conform itself: its uninstall methods take defaulted options and return the
/// process result, which Cleanup never looks at.
public struct BrewServiceCleanupRemoval: CleanupBrewRemoving {
    private let brew: BrewService

    public init(brew: BrewService) {
        self.brew = brew
    }

    public func uninstallCask(token: String) async throws {
        _ = try await brew.uninstallCask(token: token, zap: false, force: false)
    }

    public func uninstallFormula(name: String) async throws {
        _ = try await brew.uninstallFormula(name: name)
    }

    public func cleanupPackage(name: String) async throws {
        _ = try await brew.cleanupPackage(name: name)
    }
}

/// One finding the user confirmed. `inUseAcknowledged` is the second confirmation an item that a
/// running process uses needs.
public struct CleanupRemovalIntent: Equatable, Sendable {
    public let finding: CleanupFinding
    public let inUseAcknowledged: Bool

    public init(finding: CleanupFinding, inUseAcknowledged: Bool) {
        self.finding = finding
        self.inUseAcknowledged = inUseAcknowledged
    }
}

public enum CleanupRemovalOutcome: Equatable, Sendable {
    case removed
    /// Nothing Wega carries out itself: a command or instruction for the user, no action, or an
    /// action that names nothing to remove or more than one item to trash. Nothing was touched.
    case notRemovable
    case needsInUseAcknowledgement([CleanupProcess])
    /// The item is gone, is another file now, or is the current version again; ask for a rescan.
    case changedSinceScan
    case nowRequiredBy([String])
    /// The error's type and case only, never a path or a process's output.
    case failed(String)
}

/// The only Cleanup code that changes anything. Under one write lease, so no scan or update runs in
/// between, it re-checks that the item is still the one the scan identified, is not what its tool's
/// link now points to, for a D1 copy the user did not keep still leaves the kept copy working, is
/// not used by a process the user has not acknowledged, for D6 and D7 still not referenced by a
/// project or an installed IDE, for a formula still has no dependents and, for `brew cleanup`,
/// still has leftovers and no recent upgrade; only then does it act. Files only ever go to the
/// Trash.
public struct CleanupRemover: Sendable {
    static let leaseLabel = "cleanup.remove"
    private static let packageRoots = ["Cellar", "Caskroom"]

    /// Where the pointer and in-use checks look for one removed item.
    private struct Location {
        let url: URL
        let isDirectory: Bool
    }

    private struct Targets {
        let locations: [Location]
        /// The directory every location lies directly in, when they share one; a process outside
        /// it cannot use any of them.
        let enclosingDirectory: URL?
    }

    private let fileSystem: CleanupFileSystem
    private let inspector: ProcessInspecting
    private let brewQuery: CleanupBrewQuerying
    private let brewRemoval: CleanupBrewRemoving
    private let coordinator: OperationCoordinator
    private let home: URL
    private let today: @Sendable () -> Date
    private let referenceRecheck: CleanupReferenceRechecking

    public init(
        fileSystem: CleanupFileSystem, inspector: ProcessInspecting, brewQuery: CleanupBrewQuerying,
        brewRemoval: CleanupBrewRemoving, coordinator: OperationCoordinator, home: URL,
        today: @escaping @Sendable () -> Date,
        referenceRecheck: CleanupReferenceRechecking = CleanupNoReferenceRecheck()
    ) {
        self.fileSystem = fileSystem
        self.inspector = inspector
        self.brewQuery = brewQuery
        self.brewRemoval = brewRemoval
        self.coordinator = coordinator
        self.home = home
        self.today = today
        self.referenceRecheck = referenceRecheck
    }

    public func execute(_ intent: CleanupRemovalIntent) async -> CleanupRemovalOutcome {
        do {
            return try await coordinator.withWrite(label: Self.leaseLabel) {
                try await revalidateAndRemove(intent)
            }
        } catch {
            return .failed(Self.describe(error))
        }
    }

    private func revalidateAndRemove(_ intent: CleanupRemovalIntent) async throws -> CleanupRemovalOutcome {
        let finding = intent.finding
        guard Self.isRemoval(finding.action) else { return .notRemovable }
        guard let entries = try unchangedEntries(of: finding) else { return .changedSinceScan }
        let targets = try targets(of: entries, action: finding.action)
        if try isPointedToByCurrentLink(finding, locations: targets.locations) { return .changedSinceScan }
        guard isKeptCopyStillWorking(finding, locations: targets.locations) else { return .changedSinceScan }
        if case .brew(.cleanup(let name)) = finding.action {
            return try await cleanUp(name, scanned: targets.locations, inUseAcknowledged: intent.inUseAcknowledged)
        }
        let users = processesUsing(targets, of: finding)
        if !users.isEmpty, !intent.inUseAcknowledged { return .needsInUseAcknowledgement(users) }
        if Self.isJudgedByReferences(finding), try await !referenceRecheck.isStillUnreferenced(finding) {
            return .changedSinceScan
        }
        if case .brew(.uninstallFormula(let name)) = finding.action {
            let dependents = try await brewQuery.usesInstalled(formula: name)
            if !dependents.isEmpty { return .nowRequiredBy(dependents) }
        }
        try await perform(finding.action)
        return .removed
    }

    /// `brew cleanup -- <name>` removes whatever a fresh dry run lists, which may differ from what
    /// the scan saw: a package upgraded since keeps its old versions for the retention window, and
    /// a package with nothing left needs a rescan. The scanned package directory is dated before
    /// Homebrew is asked, and every package directory the dry run lists a version in after it.
    /// The command cleans a formula and a cask of that name, whichever the finding named and even
    /// when its path was a cache file, so beside each of those the same-named `Cellar/<name>` and
    /// `Caskroom/<name>` are dated too. Only the old versions the dry run lists are checked for
    /// use; the current version stays installed.
    private func cleanUp(_ name: String, scanned: [Location], inUseAcknowledged: Bool) async throws -> CleanupRemovalOutcome {
        let scannedPackages = scanned.filter { $0.isDirectory && Self.isPackageDirectory($0.url) }.map(\.url)
        if try isAnyRecentlyUpgraded(try withSameNamedPackages(scannedPackages, named: name)) { return .changedSinceScan }
        let leftovers = try await brewQuery.cleanupDryRun(package: name)
        guard !leftovers.isEmpty else { return .changedSinceScan }
        let listedPackages = Self.packageDirectories(holding: leftovers)
        if try isAnyRecentlyUpgraded(try withSameNamedPackages(listedPackages, named: name)) { return .changedSinceScan }
        let users = processesUsing(oldVersionsAmong: leftovers)
        if !users.isEmpty, !inUseAcknowledged { return .needsInUseAcknowledgement(users) }
        try await perform(.brew(.cleanup(name)))
        return .removed
    }

    /// Commands and instructions are the user's to run. A Trash action names exactly one item, the
    /// one whose identity the scan recorded. A batch must name entries directly inside its folder,
    /// because they are staged beside each other there. A Homebrew name must pass the gate before
    /// it can reach `brew`.
    private static func isRemoval(_ action: CleanupAction) -> Bool {
        switch action {
        case .trash(let urls):
            return urls.count == 1
        case .trashBatch(let parent, let entries):
            return !entries.isEmpty && entries.allSatisfy { isDirectlyInside($0, parent) }
        case .brew(let brewAction):
            return CleanupHomebrewNames.isValid(packageName(of: brewAction))
        case .command, .instruction, .uninstallApp, .none:
            return false
        }
    }

    private static func packageName(of action: CleanupBrewAction) -> String {
        switch action {
        case .uninstallFormula(let name), .cleanup(let name): name
        case .uninstallCask(let token): token
        }
    }

    /// D6 and D7 judged the item unneeded from what referenced it at scan time: the wrappers and
    /// toolchains in the projects, and the installed IDEs.
    private static func isJudgedByReferences(_ finding: CleanupFinding) -> Bool {
        guard case .trash = finding.action else { return false }
        return finding.detector == .gradle || finding.detector == .jetBrains
    }

    private static func isDirectlyInside(_ entry: URL, _ parent: URL) -> Bool {
        let components = CleanupPathText.components(of: entry.path)
        guard let name = components.last, name != ".", name != ".." else { return false }
        return Array(components.dropLast()) == CleanupPathText.components(of: parent.path)
    }

    /// The entry's name, split on scalars like `isDirectlyInside`, which has already refused an
    /// entry without one.
    private static func name(of entry: URL) -> String {
        CleanupPathText.components(of: entry.path).last ?? ""
    }

    /// The current entry of every item the action removes, or nil when one is gone or is no longer
    /// the scanned file. The scan records one identity: it pins the single trash target, a batch's
    /// folder and a Homebrew finding's own path; a batch's entries must at least still exist.
    private func unchangedEntries(of finding: CleanupFinding) throws -> [CleanupEntry]? {
        guard let scanned = finding.identity else { return nil }
        switch finding.action {
        case .trash(let urls):
            guard let entries = try existingEntries(urls) else { return nil }
            return entries.first?.identity == scanned ? entries : nil
        case .trashBatch(let parent, let urls):
            guard try fileSystem.entry(at: parent)?.identity == scanned else { return nil }
            return try existingEntries(urls)
        case .brew:
            guard let entry = try fileSystem.entry(at: finding.path), entry.identity == scanned else { return nil }
            return [entry]
        case .command, .instruction, .uninstallApp, .none:
            return nil
        }
    }

    private func existingEntries(_ urls: [URL]) throws -> [CleanupEntry]? {
        let entries = try urls.compactMap { try fileSystem.entry(at: $0) }
        return entries.count == urls.count ? entries : nil
    }

    /// Each item's resolved path. An fnm per-shell link stands for itself instead: trashing it never
    /// touches what it points to (spec D8), so a running `node` from the linked installation does
    /// not use it.
    private func targets(of entries: [CleanupEntry], action: CleanupAction) throws -> Targets {
        guard case .trashBatch(let parent, _) = action else {
            let locations = try entries.map { entry in
                Location(url: try fileSystem.realpath(entry.url), isDirectory: entry.kind == .directory)
            }
            return Targets(locations: locations, enclosingDirectory: nil)
        }
        let directory = try fileSystem.realpath(parent)
        let locations = entries.map { entry in
            Location(
                url: directory.appending(component: Self.name(of: entry.url), directoryHint: .notDirectory),
                isDirectory: entry.kind == .directory
            )
        }
        return Targets(locations: locations, enclosingDirectory: directory)
    }

    /// A native installer's link (`~/.local/bin/claude`) that now resolves to the version, or into
    /// it, made that version the current one again. A missing link points nowhere; any other
    /// failure to resolve it aborts the removal.
    private func isPointedToByCurrentLink(_ finding: CleanupFinding, locations: [Location]) throws -> Bool {
        guard case .trash = finding.action, case .nativeVersionDirectory(let tool) = finding.source else { return false }
        for layout in CleanupKnownLayouts.nativeVersionDirectories where layout.tool == tool {
            let pointer = home.appending(path: layout.pointer, directoryHint: .notDirectory)
            let pointed: URL
            do {
                pointed = try fileSystem.realpath(pointer)
            } catch CleanupFileSystemError.notFound {
                continue
            }
            let pointedComponents = CleanupPathText.components(of: pointed.path)
            if locations.contains(where: { pointedComponents.starts(with: CleanupPathText.components(of: $0.url.path)) }) {
                return true
            }
        }
        return false
    }

    /// A D1 copy the user did not keep may go only while the kept copy still works on its own:
    /// the kept path (`shadowedBy` when the kept copy is the `PATH`-active one, `keptInstead`
    /// otherwise) still resolves to an executable file, that file is not the one being removed and,
    /// for `brew uninstall`, it lies outside the package the command removes. A persisted report
    /// keeps its buttons, and once the kept copy is gone this one may be the only working copy left.
    /// Any failure to resolve it counts as gone. A candidate copy fails closed: without a kept
    /// path in its reason, or with a candidate record naming another kept copy, nothing goes.
    private func isKeptCopyStillWorking(_ finding: CleanupFinding, locations: [Location]) -> Bool {
        guard finding.detector == .pathDuplicates else { return true }
        guard let path = Self.keptPath(of: finding.reason) else { return finding.candidate == nil }
        if let candidate = finding.candidate, candidate.keep != .notKept(keptPath: path) { return false }
        guard CleanupPathText.isAbsolute(path), !CleanupPathText.containsNUL(path),
              let kept = try? fileSystem.realpath(URL(filePath: path, directoryHint: .notDirectory)),
              let entry = try? fileSystem.entry(at: kept), entry.kind == .file, entry.isExecutable
        else { return false }
        let keptComponents = CleanupPathText.components(of: kept.path)
        if locations.contains(where: { CleanupPathText.components(of: $0.url.path) == keptComponents }) { return false }
        guard case .brew(let action) = finding.action else { return true }
        guard let package = Self.package(of: action, holding: locations) else { return false }
        return !keptComponents.starts(with: package)
    }

    private static func keptPath(of reason: CleanupReason) -> String? {
        switch reason {
        case .shadowedBy(let path), .keptInstead(let path): path
        default: nil
        }
    }

    /// `<prefix>/Cellar/<name>` or `<prefix>/Caskroom/<token>` as components: what `brew uninstall`
    /// removes, read from the target's resolved path. Nil when the target no longer lies in it.
    private static func package(of action: CleanupBrewAction, holding locations: [Location]) -> [String]? {
        let (directory, name) = switch action {
        case .uninstallFormula(let name): ("Cellar", name)
        case .uninstallCask(let token): ("Caskroom", token)
        case .cleanup(let name): ("Cellar", name)
        }
        for location in locations {
            let components = CleanupPathText.components(of: location.url.path)
            if let index = components.indices.dropLast().first(where: {
                components[$0] == directory && components[$0 + 1] == name
            }) {
                return Array(components[...(index + 1)])
            }
        }
        return nil
    }

    /// The scan dated a package by its newest version directory, and so does the removal: a
    /// package upgraded within the retention window keeps its old versions, so the upgrade can
    /// still be undone. Each directory is listed once, and one that cannot be listed aborts the
    /// removal instead of reading as a package without versions.
    private func isAnyRecentlyUpgraded(_ packageDirectories: [URL]) throws -> Bool {
        try packageDirectories.contains { directory in
            guard let lastInstall = CleanupHomebrewDetector.lastInstall(among: try fileSystem.contents(of: directory)) else {
                return false
            }
            return today() < lastInstall.addingTimeInterval(UpdateOperationStore.retentionInterval)
        }
    }

    /// The package directories given and, under each one's prefix, the `Cellar/<name>` and
    /// `Caskroom/<name>` directories that exist, once each. A lookup that fails aborts the removal.
    private func withSameNamedPackages(_ packages: [URL], named name: String) throws -> [URL] {
        let shortName = CleanupPathText.components(of: name).last ?? name
        let given = packages.map { CleanupPathText.components(of: $0.path) }
        var result = given
        for package in given {
            let prefix = Array(package.dropLast(2))
            for root in Self.packageRoots {
                let sibling = prefix + [root, shortName]
                guard !result.contains(where: { Self.isSamePath($0, sibling) }),
                      try fileSystem.entry(at: Self.directory(of: sibling))?.kind == .directory else { continue }
                result.append(sibling)
            }
        }
        return result.map(Self.directory(of:))
    }

    private static func directory(of components: [String]) -> URL {
        URL(filePath: "/" + components.joined(separator: "/"), directoryHint: .isDirectory)
    }

    /// `…/Cellar/<name>` or `…/Caskroom/<token>`.
    private static func isPackageDirectory(_ url: URL) -> Bool {
        let components = CleanupPathText.components(of: url.path)
        return components.count >= 2 && isPackageRoot(components[components.count - 2])
    }

    /// The `…/Cellar/<name>` or `…/Caskroom/<token>` of every listed path that lies in a version
    /// directory, once each, read from the first `Cellar` or `Caskroom` component.
    private static func packageDirectories(holding leftovers: [CleanupBrewCleanupItem]) -> [URL] {
        var packages: [[String]] = []
        for item in leftovers {
            let components = CleanupPathText.components(of: item.path.path)
            guard let root = components.indices.first(where: { $0 + 2 < components.count && isPackageRoot(components[$0]) }) else {
                continue
            }
            let package = Array(components[...(root + 1)])
            if !packages.contains(where: { isSamePath($0, package) }) { packages.append(package) }
        }
        return packages.map(directory(of:))
    }

    private static func isPackageRoot(_ component: String) -> Bool {
        packageRoots.contains { $0.unicodeScalars.elementsEqual(component.unicodeScalars) }
    }

    private static func isSamePath(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.unicodeScalars.elementsEqual($1.unicodeScalars) }
    }

    /// The old kegs and cask versions a cleanup dry run lists, `…/Cellar/<n>/<v>` and
    /// `…/Caskroom/<t>/<v>`, under their listed and physical paths. Cache files run nothing.
    private func processesUsing(oldVersionsAmong leftovers: [CleanupBrewCleanupItem]) -> [CleanupProcess] {
        let processes = inspector.userProcesses()
        let versions = leftovers.map(\.path).filter { path in
            guard let package = CleanupHomebrewPackage.name(of: path) else { return false }
            return package.kind != .cache
        }
        let roots = versions + versions.compactMap { try? fileSystem.realpath($0) }
        let matched = roots.flatMap { CleanupInUseMatcher.processes(using: $0, isDirectory: true, among: processes) }
        return processes.filter { matched.contains($0) }
    }

    /// The processes using the targets. A Gradle daemon names its distribution only inside a
    /// `-javaagent:` or classpath argument, and an IDE its folders inside `-D` properties, so for D6
    /// and D7 an argument naming the item, under its listed or physical path, counts as well — as
    /// it did in their scan.
    private func processesUsing(_ targets: Targets, of finding: CleanupFinding) -> [CleanupProcess] {
        let processes = inspector.userProcesses()
        let users = processesUsing(targets, among: processes)
        guard Self.isJudgedByReferences(finding), case .trash(let listed) = finding.action else { return users }
        let roots = listed + targets.locations.map(\.url)
        let naming = roots.flatMap { CleanupInUseMatcher.processes(referencing: $0, among: processes) }
        return processes.filter { users.contains($0) || naming.contains($0) }
    }

    private func processesUsing(_ targets: Targets, among processes: [CleanupProcess]) -> [CleanupProcess] {
        var candidates = processes
        if let directory = targets.enclosingDirectory {
            candidates = CleanupInUseMatcher.processes(using: directory, isDirectory: true, among: candidates)
        }
        var users: [CleanupProcess] = []
        for location in targets.locations where !candidates.isEmpty {
            let matched = CleanupInUseMatcher.processes(
                using: location.url, isDirectory: location.isDirectory, among: candidates
            )
            users += matched
            candidates.removeAll { matched.contains($0) }
        }
        return users
    }

    private func perform(_ action: CleanupAction) async throws {
        switch action {
        case .trash(let urls):
            for url in urls { try fileSystem.trash(url) }
        case .trashBatch(let parent, let entries):
            try trashTogether(entries, in: parent)
        case .brew(.uninstallFormula(let name)):
            try await brewRemoval.uninstallFormula(name: name)
        case .brew(.uninstallCask(let token)):
            try await brewRemoval.uninstallCask(token: token)
        case .brew(.cleanup(let name)):
            try await brewRemoval.cleanupPackage(name: name)
        case .command, .instruction, .uninstallApp, .none:
            break
        }
    }

    /// Moves the entries into one dated folder beside them and trashes that folder, so the Trash
    /// gets one item instead of thousands. A failed move stops the batch; what was already moved
    /// stays in the folder.
    private func trashTogether(_ entries: [URL], in parent: URL) throws {
        let folder = try freeStagingFolder(in: parent)
        try fileSystem.createDirectory(folder)
        for entry in entries {
            try fileSystem.moveItem(
                entry, to: folder.appending(component: Self.name(of: entry), directoryHint: .notDirectory)
            )
        }
        try fileSystem.trash(folder)
    }

    /// `fnm_multishells-cleanup-<yyyy-MM-dd>`, or the first of `-2`, `-3`, … that is free.
    private func freeStagingFolder(in parent: URL) throws -> URL {
        let name = "fnm_multishells-cleanup-\(Self.dayStamp(today()))"
        var folder = parent.appending(component: name, directoryHint: .isDirectory)
        var suffix = 1
        while try fileSystem.entry(at: folder) != nil {
            suffix += 1
            folder = parent.appending(component: "\(name)-\(suffix)", directoryHint: .isDirectory)
        }
        return folder
    }

    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The error's type and, for an enum, its case name. Payloads are left out: they can carry a
    /// path or, for `BrewServiceError.commandFailed`, a process's output.
    static func describe(_ error: Error) -> String {
        let typeName = String(describing: type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return typeName }
        return "\(typeName).\(mirror.children.first?.label ?? String(describing: error))"
    }
}
