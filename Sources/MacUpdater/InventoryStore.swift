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

@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var apps: [ApplicationInfo] = []
    @Published private(set) var npmGlobals: [NpmGlobalPackage] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?

    private let operations: OperationCoordinator

    init(operations: OperationCoordinator = .shared) {
        self.operations = operations
    }

    func scan(
        model: AppViewModel,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        await scan(
            using: LiveInventorySnapshotLoader(model: model),
            onWegaState: onWegaState
        )
    }

    func scan(
        using loader: any InventorySnapshotLoading,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }
        onWegaState?(WegaState(pose: .sniff, line: tr("Obchód wszystkich kątów…")))

        do {
            let snapshot = try await operations.withRead(label: "inventory scan") {
                await loader.load()
            }
            apps = snapshot.apps
            npmGlobals = snapshot.npmGlobals
            errorMessage = snapshot.failures.scanErrorMessage
            onWegaState?(WegaState(
                pose: .happy,
                line: trf("Obchód skończony — %@ aplikacji pod opieką.", "\(apps.count)")
            ))
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
