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
        isReached(version: app.version, buildVersion: app.buildVersion)
    }

    /// Whether an installed version/build meets the target. A shared package is not part of
    /// the bundle's own version, so it never counts as reached here.
    func isReached(version installedVersion: String?, buildVersion: String?) -> Bool {
        guard field != .sharedPackage else { return false }
        let installed = field == .buildVersion ? buildVersion : installedVersion
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

/// Decides which vendor handoffs a completed full scan has positively confirmed.
public enum VendorHandoffScanEvidence {
    /// Handoffs whose exact installation and bundle the scan checked with the handoff's own
    /// source answering `.current`, or found on disk at a version that reaches the handoff's
    /// own completion requirement, and which the scan does not list as outdated.
    /// Failed, unchecked, missing or foreign evidence never closes a handoff.
    public static func confirmedCurrent(
        _ handoffs: [ManualOutdatedApp], installationChecks: [InstallationCheck], stillOutdated: [ManualOutdatedApp]
    ) -> [ManualOutdatedApp] {
        let outdated = Set(stillOutdated.map { InstallationIdentity(path: $0.path) })
        return handoffs.filter { item in
            let installation = InstallationIdentity(path: item.path)
            guard !outdated.contains(installation), let bundleIdentifier = item.bundleIdentifier,
                  let check = installationChecks.last(where: { InstallationIdentity(path: $0.path) == installation })
            else { return false }
            guard check.bundleIdentifier == bundleIdentifier else { return false }
            let sourceSaysCurrent = check.sources.contains {
                $0.source == item.source.completionSourceLabel && $0.outcome == .current
            }
            let diskReachesTarget = item.completionRequirement?
                .isReached(version: check.version, buildVersion: check.buildVersion) ?? false
            return sourceSaysCurrent || diskReachesTarget
        }
    }

    /// Handoffs a complete scan can no longer verify because the app is gone: no installation
    /// check for the exact path and no bundle on disk, while its parent folder is reachable. Dropping one confirms nothing.
    public static func vanished(
        _ handoffs: [ManualOutdatedApp], installationChecks: [InstallationCheck],
        scanComplete: Bool, fileExists: (URL) -> Bool
    ) -> [ManualOutdatedApp] {
        guard scanComplete else { return [] }
        let checked = Set(installationChecks.map { InstallationIdentity(path: $0.path) })
        // A missing parent directory means an unmounted volume, not an uninstalled app.
        return handoffs.filter {
            !checked.contains(InstallationIdentity(path: $0.path)) && !fileExists($0.path)
                && fileExists($0.path.deletingLastPathComponent())
        }
    }

    /// Handoffs whose own source has stopped checking their app, so neither a scan nor a
    /// recheck can ever answer for them. Dropping one confirms nothing about the update.
    public static func retired(_ handoffs: [ManualOutdatedApp]) -> [ManualOutdatedApp] {
        handoffs.filter { item in
            guard case .github = item.source, let bundleIdentifier = item.bundleIdentifier else { return false }
            return GitHubReleasesChecker.defersToDedicatedChecker(bundleIdentifier: bundleIdentifier)
        }
    }
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
        let localTargetCheck: Bool
        if case .cask(let token) = item.source {
            let service = ServiceVendorUpdateProfile.profile(caskToken: token)
            localTargetCheck = DockerDesktopUpdatePolicy.isDocker(token: token)
                || (service != nil && service == ServiceVendorUpdateProfile.profile(for: app))
        } else {
            localTargetCheck = false
        }
        let result: ManualCheckResult = localTargetCheck ? .upToDate : await checkSource(app, item.source)
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
            guard let requirement = item.completionRequirement,
                  !localTargetCheck || requirement.field != .sharedPackage else {
                return .init(app: app, outcome: .unconfirmed(.unknownTarget))
            }
            guard requirement.field == .sharedPackage || requirement.isReached(in: app) else {
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
        case .firefox, .thunderbird: return await checkMozilla(app: app, source: source)
        case .obsidian: return await ObsidianUpdateChecker().check(app: app)
        case .zed(let channel):
            guard ZedReleaseChannel(bundleIdentifier: app.bundleIdentifier) == channel else { return .notApplicable }
            return await ZedUpdateChecker().check(app: app)
        case .microsoftAutoUpdate(let applicationID):
            guard MicrosoftAutoUpdateSupport.applicationID(for: app) == applicationID else { return .notApplicable }
            return await MicrosoftAutoUpdateClient().list().check(app: app)
        case .adobe(let sapCode):
            let inventory = AdobeProductInventory.installedProducts()
            guard AdobeProductInventory.product(matching: app, in: inventory)?.sapCode == sapCode else { return .notApplicable }
            guard let catalog = try? await AdobeCatalogClient().fetchCatalog() else { return .unavailable }
            return AdobeUpdateChecker(catalog: catalog, inventory: inventory).check(app: app)
        case .cask, .mas, .wega: return .notApplicable
        }
    }
    private static func checkMozilla(app: ApplicationInfo, source: ManualOutdatedApp.UpdateSource) async -> ManualCheckResult {
        switch source {
        case .firefox(let channel):
            guard FirefoxInstallationMetadata.channel(for: app) == channel else { return .failed }
            return await FirefoxUpdateChecker().check(app: app)
        case .thunderbird(let channel):
            guard ThunderbirdInstallationChannel.read(at: app.path) == channel else { return .unavailable }
            return await ThunderbirdUpdateChecker().check(app: app)
        default: return .notApplicable
        }
    }

}
