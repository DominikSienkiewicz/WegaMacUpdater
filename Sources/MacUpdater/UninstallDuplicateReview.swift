import Foundation
import MacUpdaterCore

struct UninstallRemovalOptions: Sendable {
    let zap: Bool
    let copies: UninstallCopyPlan
}

struct UninstallDuplicateReview: Sendable {
    private struct Copy: Sendable {
        let app: ApplicationInfo
        let identity: CleanupFileIdentity
        let path: InstallationIdentity
    }

    private struct CaskBinding {
        let target: InstallationIdentity
        let appOnlyRemoval: Bool
    }

    private let apps: [ApplicationInfo]
    private let scanComplete: Bool
    private let brewPrefix: URL?
    private let fileSystem: any CleanupFileSystem
    private let copies: [Copy]
    private let targets: [String: ApplicationInfo]

    init(
        bundleIdentifier: String, apps: [ApplicationInfo], scanComplete: Bool, brewPrefix: URL?,
        fileSystem: any CleanupFileSystem = LiveCleanupFileSystem()
    ) {
        self.apps = apps.filter { $0.bundleIdentifier == bundleIdentifier }
        self.scanComplete = scanComplete
        self.brewPrefix = brewPrefix
        self.fileSystem = fileSystem
        copies = Self.physicalCopies(self.apps, fileSystem: fileSystem)
        targets = scanComplete ? Self.removalTargets(copies, brewPrefix: brewPrefix, fileSystem: fileSystem) : [:]
    }

    var visibleApps: [ApplicationInfo] {
        copies.count > 1 ? copies.map { targets[$0.app.id] ?? $0.app } : []
    }

    func target(for app: ApplicationInfo) -> ApplicationInfo? {
        targets[app.id]
    }

    /// Revalidate the selected bundle and a surviving copy under the write lease.
    func stillAllows(_ app: ApplicationInfo) -> Bool {
        guard scanComplete, let expected = copies.first(where: { $0.app.id == app.id }) else { return false }
        let current = Self.physicalCopies(apps, fileSystem: fileSystem)
        guard current.contains(where: { $0.path == expected.path && $0.identity == expected.identity }),
              current.contains(where: { other in
                  other.path != expected.path && copies.contains { $0.path == other.path && $0.identity == other.identity }
              }),
              let routed = Self.removalTargets(current, brewPrefix: brewPrefix, fileSystem: fileSystem)[app.id] else { return false }
        return app.isManagedByBrew == routed.isManagedByBrew && app.caskToken == routed.caskToken
    }

    private static func physicalCopies(_ apps: [ApplicationInfo], fileSystem: any CleanupFileSystem) -> [Copy] {
        var seen = Set<CleanupFileIdentity>()
        return apps.compactMap { app in
            guard let entry = try? fileSystem.entry(at: app.path), entry.kind == .directory,
                  let realPath = try? fileSystem.realpath(app.path),
                  let identifier = app.bundleIdentifier,
                  bundleIdentifier(at: realPath, fileSystem: fileSystem) == identifier,
                  hasMasReceipt(at: realPath, fileSystem: fileSystem) == app.isManagedByMas,
                  seen.insert(entry.identity).inserted else { return nil }
            return Copy(app: app, identity: entry.identity, path: InstallationIdentity(path: realPath))
        }
    }

    private static func removalTargets(
        _ copies: [Copy], brewPrefix: URL?, fileSystem: any CleanupFileSystem
    ) -> [String: ApplicationInfo] {
        guard copies.count > 1 else { return [:] }
        let marked = copies.filter { $0.app.isManagedByBrew }
        let tokens = Set(marked.compactMap { $0.app.caskToken })
        if marked.isEmpty { return Dictionary(uniqueKeysWithValues: copies.map { ($0.app.id, $0.app) }) }
        guard tokens.count == 1, let token = tokens.first, let brewPrefix,
              let binding = caskBinding(token: token, brewPrefix: brewPrefix, fileSystem: fileSystem),
              copies.contains(where: { $0.path == binding.target && !$0.app.isManagedByMas }) else { return [:] }
        return Dictionary(uniqueKeysWithValues: copies.compactMap { copy in
            let managed = copy.path == binding.target
            guard !managed || binding.appOnlyRemoval else { return nil }
            var app = copy.app
            app.isManagedByBrew = managed
            app.caskToken = managed ? token : nil
            return (app.id, app)
        })
    }

    private static func caskBinding(
        token: String, brewPrefix: URL, fileSystem: any CleanupFileSystem
    ) -> CaskBinding? {
        guard token.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9+@._-]*$"#, options: .regularExpression) != nil else { return nil }
        let caskDirectory = brewPrefix.appending(component: "Caskroom", directoryHint: .isDirectory)
            .appending(component: token, directoryHint: .isDirectory)
        guard let versions = try? fileSystem.contents(of: caskDirectory) else { return nil }
        var installedApps: [InstallationIdentity: String] = [:]
        for version in versions where version.kind == .directory && !version.url.lastPathComponent.hasPrefix(".") {
            guard let artifacts = try? fileSystem.contents(of: version.url) else { return nil }
            for artifact in artifacts where artifact.url.pathExtension == "app" {
                guard artifact.kind == .symlink, let path = try? fileSystem.realpath(artifact.url) else { return nil }
                installedApps[InstallationIdentity(path: path)] = artifact.url.lastPathComponent
            }
        }
        guard installedApps.count == 1, let (target, artifactName) = installedApps.first else { return nil }
        let metadata = caskDirectory.appending(component: ".metadata", directoryHint: .isDirectory)
        return receiptBinding(at: metadata, artifactName: artifactName, target: target, fileSystem: fileSystem)
    }

    /// The staged link and receipt must agree on where Homebrew installed the app. Only a
    /// cask whose uninstall describes one app and no additional operations may use Brew here.
    private static func receiptBinding(
        at metadata: URL, artifactName: String, target: InstallationIdentity, fileSystem: any CleanupFileSystem
    ) -> CaskBinding? {
        let receiptURL = metadata.appending(component: "INSTALL_RECEIPT.json", directoryHint: .notDirectory)
        let configURL = metadata.appending(component: "config.json", directoryHint: .notDirectory)
        guard let receipt = json(at: receiptURL, fileSystem: fileSystem),
              let artifacts = receipt["uninstall_artifacts"] as? [[String: Any]],
              artifacts.filter({ $0["app"] != nil }).count == 1,
              artifacts.compactMap({ $0["app"] as? [String] }) == [[artifactName]],
              let config = json(at: configURL, fileSystem: fileSystem),
              let appdir = ["explicit", "env", "default"].lazy.compactMap({ (config[$0] as? [String: Any])?["appdir"] as? String }).first,
              appdir.hasPrefix("/") else { return nil }
        let declared = URL(filePath: appdir, directoryHint: .isDirectory)
            .appending(component: artifactName, directoryHint: .isDirectory)
        guard (try? fileSystem.realpath(declared)).map(InstallationIdentity.init(path:)) == target else { return nil }
        let appOnly = receipt["loaded_from_api"] as? Bool == true
            && receipt["uninstall_flight_blocks"] as? Bool == false
            && artifacts.allSatisfy { $0.count == 1 && ($0["app"] != nil || $0["zap"] != nil) }
        return CaskBinding(target: target, appOnlyRemoval: appOnly)
    }

    private static func hasMasReceipt(at bundle: URL, fileSystem: any CleanupFileSystem) -> Bool {
        let receipt = bundle.appending(path: "Contents/_MASReceipt/receipt", directoryHint: .notDirectory)
        return (try? fileSystem.entry(at: receipt)) != nil
    }

    private static func bundleIdentifier(at bundle: URL, fileSystem: any CleanupFileSystem) -> String? {
        let plist = bundle.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = readRegularFile(plist, fileSystem: fileSystem),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return values["CFBundleIdentifier"] as? String
    }

    private static func json(at url: URL, fileSystem: any CleanupFileSystem) -> [String: Any]? {
        guard let data = readRegularFile(url, fileSystem: fileSystem) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func readRegularFile(_ url: URL, fileSystem: any CleanupFileSystem) -> Data? {
        guard (try? fileSystem.entry(at: url))?.kind == .file else { return nil }
        return try? fileSystem.readData(url, maxBytes: 1_048_576)
    }
}
