import Foundation

/// The comparison that produced an update row, kept separately from its display labels.
public struct VendorUpdateRequirement: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable {
        case shortVersion, buildVersion, sharedPackage
    }
    public let version: String
    public let field: Field
    public let scheme: VersionScheme

    public init(version: String, field: Field = .shortVersion, scheme: VersionScheme = .buildNumbered) {
        self.version = version
        self.field = field
        self.scheme = scheme
    }

    func isReached(in app: ApplicationInfo) -> Bool {
        let installed = field == .buildVersion ? app.buildVersion : app.version
        guard let installed, !installed.isEmpty, !version.isEmpty else { return false }
        let order = compareVersions(installed, version, scheme: scheme)
        return order == .orderedSame || order == .orderedDescending
    }
}

public struct VendorUpdateCompletionResult: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case unreadableApplication, identityChanged, sourceUnavailable, unknownTarget
        case targetNotReached, sharedPackage, changedDuringCheck
    }
    public enum Outcome: Equatable, Sendable {
        case confirmed
        case stillOutdated(ManualOutdatedApp)
        case unconfirmed(Reason)
    }
    public let app: ApplicationInfo?
    public let outcome: Outcome

    public init(app: ApplicationInfo?, outcome: Outcome) { self.app = app; self.outcome = outcome }
}

/// Rechecks only the selected vendor and exact bundle. Never invokes a package manager.
public struct VendorUpdateCompletionChecker: Sendable {
    private let readApplication: @Sendable (URL) -> ApplicationInfo?
    private let checkSource: @Sendable (ApplicationInfo, ManualOutdatedApp.UpdateSource) async -> ManualCheckResult

    public init() {
        self.init(readApplication: Self.application, checkSource: VendorUpdateSourceCheck.check)
    }

    public init(
        readApplication: @escaping @Sendable (URL) -> ApplicationInfo?,
        checkSource: @escaping @Sendable (ApplicationInfo, ManualOutdatedApp.UpdateSource) async -> ManualCheckResult
    ) {
        self.readApplication = readApplication
        self.checkSource = checkSource
    }

    public func check(_ item: ManualOutdatedApp) async throws -> VendorUpdateCompletionResult {
        try Task.checkCancellation()
        guard let app = readApplication(item.path) else {
            return .init(app: nil, outcome: .unconfirmed(.unreadableApplication))
        }
        guard let expectedID = item.bundleIdentifier, !expectedID.isEmpty,
              app.bundleIdentifier == expectedID, app.installation == InstallationIdentity(path: item.path) else {
            return .init(app: nil, outcome: .unconfirmed(.identityChanged))
        }
        let result = await checkSource(app, item.source)
        try Task.checkCancellation()
        guard let after = readApplication(item.path), after == app else {
            return .init(app: nil, outcome: .unconfirmed(.changedDuringCheck))
        }
        switch result {
        case .outdated(var updated):
            updated.origin = item.origin
            updated.bundleIdentifier = app.bundleIdentifier
            updated.caskPolicyToken = item.caskPolicyToken
            return .init(app: app, outcome: .stillOutdated(updated))
        case .notApplicable, .failed, .unavailable:
            return .init(app: app, outcome: .unconfirmed(.sourceUnavailable))
        case .upToDate:
            guard let requirement = item.completionRequirement else {
                return .init(app: app, outcome: .unconfirmed(.unknownTarget))
            }
            guard requirement.isReached(in: app) else {
                let reason: VendorUpdateCompletionResult.Reason = requirement.field == .sharedPackage ? .sharedPackage : .targetNotReached
                return .init(app: app, outcome: .unconfirmed(reason))
            }
            return .init(app: app, outcome: .confirmed)
        }
    }

    static func application(at path: URL) -> ApplicationInfo? {
        guard let data = try? Data(contentsOf: path.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let build = (plist["CFBundleVersion"] as? String) ?? (plist["CFBundleVersion"] as? NSNumber)?.stringValue
        return ApplicationInfo(path: path, name: path.deletingPathExtension().lastPathComponent,
                               bundleIdentifier: plist["CFBundleIdentifier"] as? String,
                               version: plist["CFBundleShortVersionString"] as? String, buildVersion: build,
                               installDate: nil, updateDate: nil, isManagedByBrew: false)
    }
}

enum VendorUpdateSourceCheck {
    static func check(app: ApplicationInfo, source: ManualOutdatedApp.UpdateSource) async -> ManualCheckResult {
        switch source {
        case .sparkle: return await SparkleUpdateChecker().check(app: app)
        case .jetbrains: return await JetBrainsUpdateChecker().check(app: app)
        case .github(let repo, let selfUpdates):
            guard let id = app.bundleIdentifier else { return .notApplicable }
            let mapping = GitHubCatalogEntry(bundleId: id, repo: repo, caskToken: "", selfUpdates: selfUpdates)
            return await GitHubReleasesChecker(repos: [id: mapping]).check(app: app)
        case .synology: return await SynologyUpdateChecker().check(app: app)
        case .antigravity: return await AntigravityUpdateChecker().check(app: app)
        case .parallels: return await ParallelsUpdateChecker().check(app: app)
        case .googleDrive: return await GoogleDriveUpdateChecker().check(app: app)
        case .chatgpt: return await ChatGPTUpdateChecker().check(app: app)
        case .postman: return await PostmanUpdateChecker().check(app: app)
        case .discord: return await DiscordUpdateChecker().check(app: app)
        case .signal: return await SignalUpdateChecker().check(app: app)
        case .chrome: return await ChromeUpdateChecker().check(app: app)
        case .obsidian: return await ObsidianUpdateChecker().check(app: app)
        case .adobe(let sapCode):
            let inventory = AdobeProductInventory.installedProducts()
            guard AdobeProductInventory.product(matching: app, in: inventory)?.sapCode == sapCode else { return .notApplicable }
            guard let catalog = try? await AdobeCatalogClient().fetchCatalog() else { return .unavailable }
            return AdobeUpdateChecker(catalog: catalog, inventory: inventory).check(app: app)
        case .cask, .mas, .wega: return .notApplicable
        }
    }
}
