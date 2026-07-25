import Foundation
import MacUpdaterCore

struct InventorySnapshot: Equatable, Sendable {
    let apps: [ApplicationInfo]
    let npmGlobals: [NpmGlobalPackage]
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
        let installedCasks = (try? await brewService.installedCasks()) ?? []
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/casks.json")
        let casks = (try? await CaskDatabaseClient(
            cache: CaskDatabaseCache(fileURL: cacheURL)
        ).fetchCasks()) ?? []
        let scanner = ApplicationScanner()
        let found = directories.flatMap { directory in
            (try? scanner.scanApplications(
                in: directory,
                installedCasks: installedCasks,
                availableCasks: casks
            )) ?? []
        }
        var apps = InstallationInventory.deduplicated(found)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if apps.contains(where: \.isManagedByMas) {
            let masApps = (try? await masService.list()) ?? []
            let masIndex = masApps.reduce(into: [:]) { index, app in
                index[StringNormalizer.normalize(app.name)] = app.appStoreID
            }
            apps = apps.map { app in
                guard app.isManagedByMas, app.masAppID == nil else { return app }
                var updated = app
                updated.masAppID = masIndex[StringNormalizer.normalize(app.name)]
                return updated
            }
        }

        return InventorySnapshot(
            apps: apps,
            npmGlobals: (try? await npmService.installedGlobals()) ?? []
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
