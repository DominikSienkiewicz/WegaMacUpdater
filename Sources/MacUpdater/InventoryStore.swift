import Foundation
import MacUpdaterCore

/// REL-14: the five independent inputs an inventory scan fans out over. Grouped into one
/// value because each is a separate failure domain — `collect` runs them independently and
/// records a `ScanSourceFailure` per source rather than letting one outage sink the scan.
struct InventorySources {
    let installedCasks: () async throws -> Set<String>
    let availableCasks: () async throws -> [BrewCask]
    let scanApplications: (
        _ directory: URL,
        _ installedCasks: Set<String>,
        _ availableCasks: [BrewCask]
    ) throws -> [ApplicationInfo]
    let masList: () async throws -> [MasInstalledApp]
    let npmGlobals: () async throws -> [NpmGlobalPackage]
}

struct InventorySnapshot: Equatable, Sendable {
    let apps: [ApplicationInfo]
    let npmGlobals: [NpmGlobalPackage]
    /// REL-14: sources that failed during the scan. Empty means the scan was clean;
    /// a non-empty value means the table is partial and the store raises the banner.
    let failures: [ScanSourceFailure]

    init(
        apps: [ApplicationInfo],
        npmGlobals: [NpmGlobalPackage],
        failures: [ScanSourceFailure] = []
    ) {
        self.apps = apps
        self.npmGlobals = npmGlobals
        self.failures = failures
    }

    /// REL-14: runs every inventory source, recording a `ScanSourceFailure` for each one
    /// that throws instead of dropping it, and keeps whatever partial data succeeded. A
    /// brew failure still returns the apps found on disk — it only records that Homebrew
    /// data is missing. Cancellation is not a scan failure, so it is never recorded.
    static func collect(
        directories: [URL],
        sources: InventorySources
    ) async -> InventorySnapshot {
        var failures: [ScanSourceFailure] = []

        var installedCaskTokens: Set<String> = []
        do { installedCaskTokens = try await sources.installedCasks() }
        catch is CancellationError {
            // Cancellation is intentionally not recorded as a source failure.
        }
        catch { failures.append(ScanSourceFailure(source: .homebrew, message: error.localizedDescription)) }

        var availableCaskList: [BrewCask] = []
        do { availableCaskList = try await sources.availableCasks() }
        catch is CancellationError {
            // Cancellation is intentionally not recorded as a source failure.
        }
        catch { failures.append(ScanSourceFailure(source: .caskCatalog, message: error.localizedDescription)) }

        var found: [ApplicationInfo] = []
        var applicationsFailure: ScanSourceFailure?
        for directory in directories {
            do {
                found.append(contentsOf: try sources.scanApplications(directory, installedCaskTokens, availableCaskList))
            } catch is CancellationError {
                // Navigation cancelled the scan — not a source failure.
            } catch {
                applicationsFailure = applicationsFailure
                    ?? ScanSourceFailure(source: .applications, message: error.localizedDescription)
            }
        }
        if let applicationsFailure { failures.append(applicationsFailure) }

        var apps = InstallationInventory.deduplicated(found)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if apps.contains(where: \.isManagedByMas) {
            do {
                let masApps = try await sources.masList()
                let masIndex = masApps.reduce(into: [:]) { index, app in
                    index[StringNormalizer.normalize(app.name)] = app.appStoreID
                }
                apps = apps.map { app in
                    guard app.isManagedByMas, app.masAppID == nil else { return app }
                    var updated = app
                    updated.masAppID = masIndex[StringNormalizer.normalize(app.name)]
                    return updated
                }
            } catch is CancellationError {
                // Cancellation is intentionally not recorded as a source failure.
            } catch {
                failures.append(ScanSourceFailure(source: .appStore, message: error.localizedDescription))
            }
        }

        var npmPackages: [NpmGlobalPackage] = []
        do { npmPackages = try await sources.npmGlobals() }
        catch is CancellationError {
            // Cancellation is intentionally not recorded as a source failure.
        }
        catch { failures.append(ScanSourceFailure(source: .npm, message: error.localizedDescription)) }

        return InventorySnapshot(apps: apps, npmGlobals: npmPackages, failures: failures)
    }
}

protocol InventorySnapshotLoading: Sendable {
    func load() async -> InventorySnapshot
}

struct LiveInventorySnapshotLoader: InventorySnapshotLoading {
    private let brewService: BrewService
    private let masService: MasService
    private let npmService: NpmGlobalService
    private let directories: [URL]

    @MainActor
    init(model: AppViewModel, directories: [URL] = buildScanDirs()) {
        brewService = model.brewService
        masService = model.masService
        npmService = model.npmService
        self.directories = directories
    }

    func load() async -> InventorySnapshot {
        let scanner = ApplicationScanner()
        return await InventorySnapshot.collect(
            directories: directories,
            sources: InventorySources(
                installedCasks: { try await brewService.installedCasks() },
                availableCasks: {
                    try await CaskDatabaseClient.caskCatalog().fetchCasks()
                },
                scanApplications: { directory, installedCasks, availableCasks in
                    try scanner.scanApplications(
                        in: directory,
                        installedCasks: installedCasks,
                        availableCasks: availableCasks
                    )
                },
                masList: { try await masService.list() },
                npmGlobals: { try await npmService.installedGlobals() }
            )
        )
    }
}

/// UXP-30 — how many of the actions that change the installed apps have finished: update runs,
/// migrations (duplicate removals included), Cleanup removals and background rounds that
/// installed something, manual installs, reinstalls and undos. Each count lives on the store that runs the action, and those stores
/// live in the app rather than in the window, so an action that finishes while the window is
/// closed still counts. The inventory keeps the counts its last read started from.
struct InventoryChangeStamp: Equatable, Sendable {
    var updateRuns = 0
    var migrations = 0
    var cleanupRemovals = 0
    var backgroundInstalls = 0
    var manualInstalls = 0
    var undos = 0
}

extension InventoryChangeStamp {
    /// The counts now, read off the stores that run each action. The Inventory screen and the
    /// Updates search ask the same question of the same read, so both build the stamp here.
    @MainActor
    static func current(scan: ScanStore, migration: MigrationStore, cleanup: CleanupStore, menuBar: MenuBarAgent) -> Self {
        InventoryChangeStamp(
            updateRuns: scan.completedRunCount,
            migrations: migration.completedCount,
            cleanupRemovals: cleanup.removalCount,
            backgroundInstalls: menuBar.installedRoundCount,
            manualInstalls: scan.completedManualInstallCount,
            undos: scan.completedUndoCount
        )
    }
}

@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var apps: [ApplicationInfo] = []
    @Published private(set) var npmGlobals: [NpmGlobalPackage] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?

    /// When the last successful read finished, partial reads included. `nil` until then;
    /// a cancelled or failed read leaves it alone.
    @Published private(set) var lastReadAt: Date?
    @Published private(set) var footprintMeasurement: InventoryFootprintMeasurement?
    @Published private(set) var footprintFailureRead: Date?
    /// Set by a change no store counts: an uninstall reports itself through `markStale()`.
    @Published private var markedStale = false
    /// The counts the last successful read started from.
    private var changesAtLastRead = InventoryChangeStamp()

    private let operations: OperationCoordinator
    private let now: @MainActor () -> Date

    init(operations: OperationCoordinator = .shared, now: @escaping @MainActor () -> Date = { .now }) {
        self.operations = operations
        self.now = now
    }

    /// Whether the list may no longer match the disk: something counted in `changes` finished
    /// after the last read started, or an uninstall said so.
    func isStale(given changes: InventoryChangeStamp) -> Bool {
        markedStale || changes != changesAtLastRead
    }

    /// True until the first read has landed, and again once the list is stale. The store
    /// outlives the view, so a second visit with nothing changed reuses the result.
    func needsRead(given changes: InventoryChangeStamp) -> Bool {
        (lastReadAt == nil || isStale(given: changes)) && !isScanning
    }

    func scan(
        model: AppViewModel,
        changes: InventoryChangeStamp,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        await scan(
            using: LiveInventorySnapshotLoader(model: model),
            changes: changes,
            onWegaState: onWegaState
        )
    }

    /// An uninstall changed the app set behind the list. The list stays on screen, but it no
    /// longer claims to be current and the next entry reads again.
    func markStale() { markedStale = true }

    func measureFootprints(for read: Date) async {
        guard lastReadAt == read, !isScanning, footprintMeasurement?.readAt != read else { return }
        let installations = apps
        footprintFailureRead = nil
        do {
            let sizes = try await operations.withRead(label: "inventory sizes") {
                try await InventoryFootprintReader().measure(installations)
            }
            try Task.checkCancellation()
            guard lastReadAt == read, !isScanning else { return }
            let report = try await InventoryFootprintHistory.shared.record(sizes, apps: installations, readAt: read)
            guard lastReadAt == read, !Task.isCancelled else { return }
            footprintMeasurement = report
        } catch is CancellationError {
            return
        } catch {
            if lastReadAt == read { footprintFailureRead = read }
        }
    }

    func scan(
        using loader: any InventorySnapshotLoading,
        changes: InventoryChangeStamp,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        // A change that lands while this read runs moves the counts past `changes`, or sets the
        // flag again, and survives it.
        let wasStale = markedStale
        markedStale = false
        defer { isScanning = false }
        onWegaState?(WegaState(pose: .sniff, line: tr("Obchód wszystkich kątów…")))

        do {
            let snapshot = try await operations.withRead(label: "inventory scan") {
                await loader.load()
            }
            apps = snapshot.apps
            npmGlobals = snapshot.npmGlobals
            errorMessage = snapshot.failures.scanErrorMessage
            changesAtLastRead = changes
            lastReadAt = now()
            onWegaState?(WegaState(
                pose: .happy,
                line: trp("Obchód skończony — %@ aplikacji pod opieką.", apps.count)
            ))
        } catch is CancellationError {
            markedStale = markedStale || wasStale
            return
        } catch {
            markedStale = markedStale || wasStale
            errorMessage = error.localizedDescription
        }
    }
}
