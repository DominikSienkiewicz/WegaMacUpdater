import Foundation
import MacUpdaterCore

/// REL-14: the result of an uninstall scan — the apps found plus every source that
/// failed. `UninstallView` keeps the two apart so a scan failure is never rendered as
/// "no apps found", and warns before a destructive action taken on partial data.
struct UninstallScan: Equatable, Sendable {
    let apps: [ApplicationInfo]
    let failures: [ScanSourceFailure]

    var scanFailed: Bool { !failures.isEmpty }

    init(apps: [ApplicationInfo], failures: [ScanSourceFailure] = []) {
        self.apps = apps
        self.failures = failures
    }

    /// Runs each uninstall source, recording a `ScanSourceFailure` for one that throws
    /// rather than dropping it, and keeps the apps found by the sources that succeeded.
    /// Cancellation is not a scan failure, so it is never recorded.
    static func collect(
        directories: [URL],
        installedCasks: () async throws -> Set<String>,
        scanApplications: (_ directory: URL, _ installedCasks: Set<String>) throws -> [ApplicationInfo]
    ) async -> UninstallScan {
        var failures: [ScanSourceFailure] = []

        var installedCaskTokens: Set<String> = []
        do { installedCaskTokens = try await installedCasks() }
        catch is CancellationError {}
        catch { failures.append(ScanSourceFailure(source: .homebrew, message: error.localizedDescription)) }

        var found: [ApplicationInfo] = []
        var applicationsFailure: ScanSourceFailure?
        for directory in directories {
            do {
                found.append(contentsOf: try scanApplications(directory, installedCaskTokens))
            } catch is CancellationError {
                // Navigation cancelled the scan — not a source failure.
            } catch {
                applicationsFailure = applicationsFailure
                    ?? ScanSourceFailure(source: .applications, message: error.localizedDescription)
            }
        }
        if let applicationsFailure { failures.append(applicationsFailure) }

        let apps = InstallationInventory.deduplicated(found)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return UninstallScan(apps: apps, failures: failures)
    }
}

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

    func scan(using brewService: BrewService) async -> UninstallScan {
        guard state == .idle else { return UninstallScan(apps: []) }
        state = .scanning
        defer { state = .idle }

        let directories = buildScanDirs()
        do {
            return try await OperationCoordinator.shared.withRead(label: "uninstall scan") {
                let scanner = ApplicationScanner()
                return await UninstallScan.collect(
                    directories: directories,
                    installedCasks: { try await brewService.installedCasks() },
                    scanApplications: { directory, installedCasks in
                        try scanner.scanApplications(in: directory, installedCasks: installedCasks)
                    }
                )
            }
        } catch {
            return UninstallScan(apps: [])
        }
    }

    func uninstall(
        targets: [ApplicationInfo],
        zap: Bool,
        using brewService: BrewService
    ) async -> Outcome {
        do {
            return try await UpgradeCoordinator.shared.performWrite(.uninstall) {
                await self.uninstallCoordinated(targets: targets, zap: zap, using: brewService)
            }
        } catch {
            return Outcome(succeeded: [], failedIDs: Set(targets.map(\.id)))
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
