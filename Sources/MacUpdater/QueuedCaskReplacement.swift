import Foundation
import MacUpdaterCore

struct QueuedCaskReplacement: Equatable, Sendable {
    let app: ManualOutdatedApp
    let token: String

    var key: String { Self.key(for: app) }
    var ownsInstallation: Bool { app.caskPolicyToken == token }
    var directory: URL { app.path.deletingLastPathComponent() }
    var item: OutdatedItem {
        OutdatedItem(key: key, name: token, from: app.installedVersion, to: app.availableVersion,
                     kind: .cask, releaseNotes: app.releaseNotes)
    }

    static func key(for app: ManualOutdatedApp) -> String { "m:" + app.path.path }

    static func candidates(
        in apps: [ManualOutdatedApp], installations: [InstallationCheck],
        regularCasks: Set<String>, profiles: [String: CaskArtifactProfile]
    ) -> [Self] {
        let supportedDirectories = [
            SystemPaths.applicationsDirectory,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ].map { $0.standardizedFileURL.path }
        let byBundleID = Dictionary(grouping: installations.compactMap { installation in
            installation.bundleIdentifier.map { ($0, InstallationIdentity(path: installation.path)) }
        }, by: \.0)
        let caskApps = apps.compactMap { app -> Self? in
            guard case .cask(let token) = app.source else { return nil }
            return Self(app: app, token: token)
        }
        let tokens = Dictionary(grouping: caskApps, by: \.token)
        return caskApps.filter { candidate in
            guard let identifier = candidate.app.bundleIdentifier, !identifier.isEmpty,
                  candidate.app.path.isFileURL, supportedDirectories.contains(candidate.directory.standardizedFileURL.path),
                  let profile = profiles[candidate.token], candidate.isSupported(profile),
                  !candidate.app.rolledBack, candidate.app.origin != .appStore,
                  candidate.app.installedVersion?.isEmpty == false,
                  candidate.app.availableVersion?.isEmpty == false,
                  !regularCasks.contains(candidate.token), tokens[candidate.token]?.count == 1,
                  !DockerDesktopUpdatePolicy.isDocker(candidate.app),
                  ServiceVendorUpdatePolicy.profile(for: candidate.app) == nil else { return false }

            let identity = InstallationIdentity(path: candidate.app.path)
            let otherInstallations = byBundleID[identifier]?.map(\.1) ?? []
            return otherInstallations.allSatisfy { $0 == identity }
                && !installations.contains { installation in
                    let path = InstallationIdentity(path: installation.path)
                    return (installation.caskToken == candidate.token && path != identity)
                        || (path == identity && (installation.isManagedByMas || installation.unconfirmedCaskToken != nil))
                }
        }
    }

    func isSupported(_ profile: CaskArtifactProfile) -> Bool {
        RollbackProtection.evaluate(profile: profile) == .protected
            && app.path.pathExtension.lowercased() == "app"
            && profile.appArtifacts == [app.path.lastPathComponent]
    }

    func arguments(catalogVersion: String, recordedVersion: String?) -> [String] {
        var arguments = CaskAdoptionCommand.arguments(
            token: token, offeredVersion: catalogVersion, recordedVersion: recordedVersion
        )
        arguments.insert("--appdir=\(directory.path)", at: arguments.count - 2)
        return arguments
    }

    func hasExactDestination(resolver: CaskReplacementArtifactLocationResolver = .init()) -> Bool {
        let artifact = app.path.lastPathComponent
        guard case .resolved(let destination) = resolver.resolve(artifact: artifact) else { return false }
        let path = destination.standardizedFileURL.path
        return path == app.path.standardizedFileURL.path
            && path == destination.resolvingSymlinksInPath().standardizedFileURL.path
    }

    var reachedApprovedVersion: Bool {
        guard CaskReplacementArtifactIdentity.bundleIdentifier(at: app.path) == app.bundleIdentifier,
              let current = UpdateOperationRecoveryPlan.bundleShortVersion(at: app.path), let target = app.availableVersion else { return false }
        return versionsEqual(current, target) || isUpgrade(installed: target, latest: current)
    }

    func matchesOnDisk() -> Bool {
        CaskReplacementArtifactIdentity.bundleIdentifier(at: app.path) == app.bundleIdentifier
            && UpdateOperationRecoveryPlan.bundleShortVersion(at: app.path) == app.installedVersion
            && !FileManager.default.fileExists(atPath: app.path.appendingPathComponent("Contents/_MASReceipt/receipt").path)
    }
}

extension ScanStore {
    func queueableCaskReplacements(for filter: UpdateFilter) -> [QueuedCaskReplacement] {
        guard filter != .cli else { return [] }
        let apps = visibleManual
        let regularCasks = Set(brewOutdated?.casks.map(\.name) ?? [])
        return QueuedCaskReplacement.candidates(
            in: apps, installations: installationChecks, regularCasks: regularCasks, profiles: caskProfiles
        ).filter { !filter.isSecurityOnly || isSecurityApp($0.app) }
    }

    func toggleQueuedCaskReplacement(_ app: ManualOutdatedApp) {
        guard ScanSelectionGate.allowsListSelection(isRefreshing: isRefreshing, isUpdating: updating),
              queueableCaskReplacements(for: .all).contains(where: { $0.app == app }) else { return }
        let key = QueuedCaskReplacement.key(for: app)
        if selected.remove(key) == nil { selected.insert(key) }
    }
}
