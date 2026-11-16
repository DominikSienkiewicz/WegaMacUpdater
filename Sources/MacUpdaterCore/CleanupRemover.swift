import Foundation

/// Uninstalls one Homebrew package for Cleanup; never with `--zap` or `--force`.
public protocol CleanupBrewRemoving: Sendable {
    func uninstallCask(token: String) async throws
    func uninstallFormula(name: String) async throws
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
/// link now points to, is still shadowed by a working copy of its own when D1 found it shadowed, is
/// not used by a process the user has not acknowledged and, for a formula, still has no
/// dependents; only then does it act. Files only ever go to the Trash.
public struct CleanupRemover: Sendable {
    static let leaseLabel = "cleanup.remove"

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

    public init(
        fileSystem: CleanupFileSystem, inspector: ProcessInspecting, brewQuery: CleanupBrewQuerying,
        brewRemoval: CleanupBrewRemoving, coordinator: OperationCoordinator, home: URL,
        today: @escaping @Sendable () -> Date
    ) {
        self.fileSystem = fileSystem
        self.inspector = inspector
        self.brewQuery = brewQuery
        self.brewRemoval = brewRemoval
        self.coordinator = coordinator
        self.home = home
        self.today = today
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
        guard isStillShadowed(finding, locations: targets.locations) else { return .changedSinceScan }
        let users = processesUsing(targets)
        if !users.isEmpty, !intent.inUseAcknowledged { return .needsInUseAcknowledgement(users) }
        if case .brew(.uninstallFormula(let name)) = finding.action {
            let dependents = try await brewQuery.usesInstalled(formula: name)
            if !dependents.isEmpty { return .nowRequiredBy(dependents) }
        }
        try await perform(finding.action)
        return .removed
    }

    /// Commands and instructions are the user's to run. A Trash action names exactly one item, the
    /// one whose identity the scan recorded. A batch must name entries directly inside its folder,
    /// because they are staged beside each other there.
    private static func isRemoval(_ action: CleanupAction) -> Bool {
        switch action {
        case .trash(let urls):
            return urls.count == 1
        case .trashBatch(let parent, let entries):
            return !entries.isEmpty && entries.allSatisfy { isDirectlyInside($0, parent) }
        case .brew(.cleanup):
            return false
        case .brew:
            return true
        case .command, .instruction, .none:
            return false
        }
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
        case .command, .instruction, .none:
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

    /// A copy D1 found shadowed may go only while the copy that shadowed it still works on its
    /// own: that path still resolves to an executable file, that file is not the one being
    /// removed and, for `brew uninstall`, it lies outside the package the command removes. A
    /// persisted report keeps its buttons, and once the active copy is gone the shadowed one may be
    /// the only working copy left. Any failure to resolve it counts as gone.
    private func isStillShadowed(_ finding: CleanupFinding, locations: [Location]) -> Bool {
        guard finding.detector == .pathDuplicates, case .shadowedBy(let path) = finding.reason else { return true }
        guard CleanupPathText.isAbsolute(path), !CleanupPathText.containsNUL(path),
              let active = try? fileSystem.realpath(URL(filePath: path, directoryHint: .notDirectory)),
              let entry = try? fileSystem.entry(at: active), entry.kind == .file, entry.isExecutable
        else { return false }
        let activeComponents = CleanupPathText.components(of: active.path)
        if locations.contains(where: { CleanupPathText.components(of: $0.url.path) == activeComponents }) { return false }
        guard case .brew(let action) = finding.action else { return true }
        guard let package = Self.package(of: action, holding: locations) else { return false }
        return !activeComponents.starts(with: package)
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

    private func processesUsing(_ targets: Targets) -> [CleanupProcess] {
        var candidates = inspector.userProcesses()
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
        case .brew(.cleanup):
            break
        case .command, .instruction, .none:
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
