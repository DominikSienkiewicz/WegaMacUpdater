import Foundation
import MacUpdaterCore

/// Performs application discovery and destructive uninstall I/O outside SwiftUI.
@MainActor
final class UninstallCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case uninstalling
    }

    struct Outcome {
        let succeeded: Set<String>
        let failedIDs: Set<String>
    }

    @Published private(set) var state: State = .idle

    var isScanning: Bool { state == .scanning }
    var isUninstalling: Bool { state == .uninstalling }

    func scan(using brewService: BrewService) async -> [ApplicationInfo] {
        guard state == .idle else { return [] }
        state = .scanning
        defer { state = .idle }

        let directories = buildScanDirs()
        return await OperationCoordinator.shared.withRead(label: "uninstall scan") {
            let installedCasks = (try? await brewService.installedCasks()) ?? []
            let scanner = ApplicationScanner()
            let found = directories.flatMap { directory in
                (try? scanner.scanApplications(in: directory, installedCasks: installedCasks)) ?? []
            }
            return InstallationInventory.deduplicated(found)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func uninstall(
        targets: [ApplicationInfo],
        zap: Bool,
        using brewService: BrewService
    ) async -> Outcome {
        await UpgradeCoordinator.shared.performWrite(.uninstall) {
            await self.uninstallCoordinated(targets: targets, zap: zap, using: brewService)
        }
    }

    private func uninstallCoordinated(
        targets: [ApplicationInfo],
        zap: Bool,
        using brewService: BrewService
    ) async -> Outcome {
        state = .uninstalling
        defer { state = .idle }

        var succeeded: Set<String> = []
        var failedIDs: Set<String> = []
        for app in targets {
            if app.isManagedByBrew, let token = app.caskToken {
                do {
                    _ = try await brewService.uninstallCask(token: token, zap: zap)
                    succeeded.insert(app.id)
                } catch {
                    failedIDs.insert(app.id)
                }
            } else {
                do {
                    try FileManager.default.trashItem(at: app.path, resultingItemURL: nil)
                    succeeded.insert(app.id)
                } catch {
                    failedIDs.insert(app.id)
                }
            }
        }
        return Outcome(succeeded: succeeded, failedIDs: failedIDs)
    }
}
