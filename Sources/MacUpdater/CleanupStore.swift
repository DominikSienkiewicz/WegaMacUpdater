import Foundation
import MacUpdaterCore

/// Everything `CleanupStore` reaches the system through. Tests replace every closure; `live` wires
/// the guarded file system, the process inspector, Homebrew and the shared operation coordinator.
struct CleanupStoreDependencies {
    /// The home the scan and the remover were built for; removal log lines show it as `~`.
    var home: URL
    var coordinator: OperationCoordinator
    var readPath: @Sendable () async -> CleanupPathReadResult
    var approximatePath: @Sendable () -> CleanupPathSnapshot
    var scan: @Sendable (CleanupPathSnapshot) async throws -> CleanupReport
    var remove: @Sendable (CleanupRemovalIntent) async -> CleanupRemovalOutcome
    var loadReport: @MainActor () -> CleanupReport?
    var saveReport: @MainActor (CleanupReport) throws -> Void
    var loadPath: @MainActor () -> CleanupPathSnapshot?
    var savePath: @MainActor (CleanupPathSnapshot) throws -> Void

    /// One guarded file system serves the scan, the approximate `PATH` and the remover, so every
    /// Cleanup read and every move to the Trash passes the protected-location guard.
    static var live: CleanupStoreDependencies {
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        let tmpDirectory = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? SystemPaths.defaultLoginShell
        let fileSystem = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(),
            guard: ProtectedLocationGuard(home: home, mounts: LiveMountTable())
        )
        let inspector = LiveProcessInspector()
        let brew = BrewService()
        let coordinator = OperationCoordinator.shared
        let remover = CleanupRemover(
            fileSystem: fileSystem, inspector: inspector, brewQuery: brew,
            brewRemoval: BrewServiceCleanupRemoval(brew: brew), coordinator: coordinator, home: home,
            today: Date.init
        )
        return CleanupStoreDependencies(
            home: home,
            coordinator: coordinator,
            readPath: {
                await CleanupPathReader(
                    runner: ProcessRunner(), shellPath: shellPath, home: home, user: NSUserName(), now: Date.init
                ).read()
            },
            approximatePath: { CleanupApproximatePath.build(fileSystem: fileSystem, home: home) },
            scan: { path in
                try await CleanupScanner().scan(CleanupContext(
                    home: home, tmpDirectory: tmpDirectory, path: path, fileSystem: fileSystem,
                    inspector: inspector, brew: brew, brewPrefix: BinaryLocator().locateBrewPrefix()
                ))
            },
            remove: { await remover.execute($0) },
            loadReport: { CleanupReportFile(home: home).load() },
            saveReport: { try CleanupReportFile(home: home).save($0) },
            loadPath: { CleanupPathSnapshotFile().load() },
            savePath: { try CleanupPathSnapshotFile().save($0) }
        )
    }
}

/// State of the Cleanup ("Porządki") destination and the one operation it runs at a time: the
/// shell `PATH` read, a scan, or a confirmed removal followed by its rescan.
///
/// Held by the `App` above `.id(localization.language)`, like `ScanStore` and `MigrationStore`:
/// the re-key destroys the view tree, and a running scan or removal must outlive it.
@MainActor
final class CleanupStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case readingPath
        case scanning
        case removing(findingID: String)
    }

    private static let scanLeaseLabel = "cleanup.scan"

    @Published private(set) var report: CleanupReport?
    @Published private(set) var phase: Phase = .idle
    /// The last `PATH` read from the login shell; nil until one succeeds.
    @Published private(set) var pathSnapshot: CleanupPathSnapshot?
    @Published private(set) var lastOutcome: CleanupRemovalOutcome?
    @Published private(set) var pathReadResult: CleanupPathReadResult?
    /// The last scan ended in an error other than a cancellation, so the report on screen is older
    /// than the user's request. Cleared when a scan starts.
    @Published private(set) var lastScanFailed = false

    /// The running operation `phase` names. Internal so tests can await it.
    private(set) var task: Task<Void, Never>?

    private let dependencies: CleanupStoreDependencies

    init(dependencies: CleanupStoreDependencies = .live) {
        self.dependencies = dependencies
        report = dependencies.loadReport()
        pathSnapshot = dependencies.loadPath()
    }

    /// Runs the user's login shell once. Only a captured `PATH` replaces the stored one; an
    /// unsupported shell or a failed read leaves it and is reported through `pathReadResult`.
    func readPath() {
        start(.readingPath) {
            self.pathReadResult = nil
            let result = await self.dependencies.readPath()
            self.pathReadResult = result
            guard case .captured(let snapshot) = result else { return }
            self.pathSnapshot = snapshot
            self.persist("PATH") { try self.dependencies.savePath(snapshot) }
        }
    }

    /// Scans with the stored shell `PATH`, or with the approximate one when none was read.
    func scan() {
        start(.scanning) { await self.performScan() }
    }

    /// Stops a running scan, which leaves the previous report in place. A removal is never
    /// cancelled: a `brew uninstall` killed halfway leaves a half-removed package behind.
    func cancel() {
        guard phase == .scanning else { return }
        task?.cancel()
    }

    /// Carries out one confirmed removal; the remover re-validates it under a write lease. Only a
    /// `.removed` outcome is logged and followed by a rescan; any other outcome is left for the
    /// view to explain through `lastOutcome`.
    func remove(_ intent: CleanupRemovalIntent) {
        start(.removing(findingID: intent.finding.id)) {
            self.lastOutcome = nil
            let outcome = await self.dependencies.remove(intent)
            self.lastOutcome = outcome
            guard outcome == .removed else { return }
            WegaLog.info(.app, Self.removalLogLine(for: intent.finding, home: self.dependencies.home))
            self.phase = .scanning
            await self.performScan()
        }
    }

    /// The finding's path with `~` for the home and the kind of action taken. Never the processes
    /// that used it: their arguments can carry tokens.
    static func removalLogLine(for finding: CleanupFinding, home: URL) -> String {
        let path = CleanupReportRenderer.tildePath(finding.path.path, home: home)
        return "Porządki: usunięto \(path) (\(actionKind(finding.action)))"
    }

    private static func actionKind(_ action: CleanupAction) -> String {
        switch action {
        case .trash: "trash"
        case .trashBatch: "trash-batch"
        case .brew(.uninstallFormula): "brew uninstall"
        case .brew(.uninstallCask): "brew uninstall --cask"
        case .command: "command"
        case .instruction: "instruction"
        case .none: "none"
        }
    }

    /// Starts `work` unless another operation is running; `phase` returns to idle when it ends.
    private func start(_ phase: Phase, _ work: @escaping @MainActor () async -> Void) {
        guard self.phase == .idle else { return }
        self.phase = phase
        task = Task {
            await work()
            self.phase = .idle
            self.task = nil
        }
    }

    /// Under a read lease, so no removal or update changes the disk while the scan reads it.
    private func performScan() async {
        lastScanFailed = false
        let storedPath = pathSnapshot
        let approximatePath = dependencies.approximatePath
        let scan = dependencies.scan
        do {
            let report = try await dependencies.coordinator.withRead(label: Self.scanLeaseLabel) {
                try await scan(storedPath ?? approximatePath())
            }
            self.report = report
            lastScanFailed = false
            persist("raportu") { try dependencies.saveReport(report) }
        } catch is CancellationError {
            WegaLog.info(.app, "Porządki: skan anulowany, poprzedni raport zostaje.")
        } catch {
            lastScanFailed = true
            WegaLog.warning(.app, "Porządki: skan nie powiódł się (\(type(of: error))).")
        }
    }

    /// A failed write costs only the copy shown at the next launch, so it is logged, not raised.
    private func persist(_ what: String, _ write: () throws -> Void) {
        do {
            try write()
        } catch {
            WegaLog.warning(.app, "Porządki: nie zapisano \(what) (\(type(of: error))).")
        }
    }
}
