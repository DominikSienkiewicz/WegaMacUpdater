import Foundation

/// Installed services keep control of updates, including their administrator's rollout policy.
public enum ServiceVendorUpdateProfile: Equatable, Sendable {
    case cloudflareWarp, bitdefender, logiOptionsPlus

    public static func profile(for app: ApplicationInfo) -> Self? {
        profile(bundleIdentifier: app.bundleIdentifier)
    }

    public static func profile(bundleIdentifier: String?) -> Self? {
        switch bundleIdentifier {
        case "com.cloudflare.1dot1dot1dot1.macos": .cloudflareWarp
        case BitdefenderSupport.bundleIdentifier: .bitdefender
        case "com.logi.optionsplus": .logiOptionsPlus
        default: nil
        }
    }

    public static func profile(caskToken: String) -> Self? {
        switch caskToken.split(separator: "/").last.map(String.init) {
        case "cloudflare-warp": .cloudflareWarp
        case "logi-options+": .logiOptionsPlus
        default: nil
        }
    }

    /// The bundle identifier of the app this profile describes.
    public var bundleIdentifier: String {
        switch self {
        case .cloudflareWarp: "com.cloudflare.1dot1dot1dot1.macos"
        case .bitdefender: BitdefenderSupport.bundleIdentifier
        case .logiOptionsPlus: "com.logi.optionsplus"
        }
    }

    public var updateActionKind: UpdateActionKind { .launchApp }

    public var name: String {
        switch self {
        case .cloudflareWarp: "Cloudflare WARP"
        case .bitdefender: "Bitdefender Antivirus for Mac"
        case .logiOptionsPlus: "Logi Options+"
        }
    }

    public var instructions: String {
        switch self {
        case .cloudflareWarp:
            "Otwórz WARP i użyj aktualizacji dostępnej w aplikacji. W organizacji wersją może zarządzać MDM lub panel Cloudflare. Jeśli aktualizacja jest niedostępna, skontaktuj się z administratorem."
        case .bitdefender:
            "W Bitdefender wybierz Actions → Update threat information database. Aktualizacja produktu może wymagać restartu. Wersja aplikacji nie potwierdza aktualności definicji zagrożeń."
        case .logiOptionsPlus:
            "Otwórz Logi Options+ i sprawdź aktualizacje w ustawieniach aplikacji. Instalacjami firmowymi może zarządzać administrator."
        }
    }

    public var supportURL: URL? {
        switch self {
        case .cloudflareWarp:
            URL(string: "https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/download/update/")
        case .bitdefender:
            URL(string: "https://www.bitdefender.com/consumer/support/answer/32547/")
        case .logiOptionsPlus:
            URL(string: "https://hub.sync.logitech.com/options/post/logi-options-offline-manual-I2a7NSJyE6oH2oy")
        }
    }
}

public enum ServiceVendorUpdatePolicy {
    public static func requiresVendor(token: String) -> Bool {
        ServiceVendorUpdateProfile.profile(caskToken: token) != nil
    }

    /// Whether a complete scan found no installation of the vendor app behind `token`, so a
    /// Homebrew record for it is a leftover rather than an update. An incomplete scan, or a
    /// token no profile describes, never counts as "not installed".
    public static func isNotInstalled(token: String, installationChecks: [InstallationCheck], scanComplete: Bool) -> Bool {
        guard scanComplete, let profile = ServiceVendorUpdateProfile.profile(caskToken: token) else { return false }
        return !installationChecks.contains { $0.bundleIdentifier == profile.bundleIdentifier }
    }

    /// Tokens of Homebrew's outdated vendor-service casks that are no update to show: no app
    /// carries the profile's bundle identifier (a leftover Caskroom record), or every such
    /// app is already at or above the cask's target (Homebrew's record is stale). Only the first
    /// needs a complete scan: an installed copy at the target is positive evidence on its own.
    public static func staleVendorTokens(
        outdated casks: [BrewOutdatedItem], installationChecks: [InstallationCheck], scanComplete: Bool
    ) -> Set<String> {
        Set(casks.compactMap { cask -> String? in
            guard let profile = ServiceVendorUpdateProfile.profile(caskToken: cask.name) else { return nil }
            let installed = installationChecks.filter { $0.bundleIdentifier == profile.bundleIdentifier }
            if isNotInstalled(token: cask.name, installationChecks: installationChecks, scanComplete: scanComplete) {
                return cask.name
            }
            if installed.isEmpty { return nil }
            guard let target = cask.currentVersion, !target.isEmpty else { return nil }
            let requirement = VendorUpdateRequirement(version: target)
            let allCurrent = installed.allSatisfy {
                requirement.isReached(version: $0.version, buildVersion: $0.buildVersion)
            }
            return allCurrent ? cask.name : nil
        })
    }

    public static func profile(for item: ManualOutdatedApp) -> ServiceVendorUpdateProfile? {
        ServiceVendorUpdateProfile.profile(bundleIdentifier: item.bundleIdentifier)
    }

    public static func eligibleKeys(_ keys: Set<String>) -> Set<String> {
        keys.filter { !$0.hasPrefix("c:") || !requiresVendor(token: String($0.dropFirst(2))) }
    }

    public static func batchItems(_ items: [OutdatedItem]) -> [OutdatedItem] {
        items.filter { $0.kind != .cask || !requiresVendor(token: $0.name) }
    }

    /// A package-manager update remains visible, but only its verified installation can be opened.
    public static func managedUpdates(
        items: [OutdatedItem], appPaths: [String: URL], installationChecks: [InstallationCheck]
    ) -> [ManualOutdatedApp] {
        items.compactMap { item in
            guard item.kind == .cask,
                  let profile = ServiceVendorUpdateProfile.profile(caskToken: item.name),
                  let check = resolvedInstallation(token: item.name, appPaths: appPaths, checks: installationChecks),
                  check.path.isFileURL,
                  ServiceVendorUpdateProfile.profile(bundleIdentifier: check.bundleIdentifier) == profile
            else { return nil }
            let requirement = item.to.flatMap { $0.isEmpty ? nil : VendorUpdateRequirement(version: $0) }
            // Homebrew still records the old version of an app that updated itself.
            if requirement?.isReached(version: check.version, buildVersion: check.buildVersion) == true { return nil }
            return ManualOutdatedApp(
                name: profile.name, path: check.path, installedVersion: check.version ?? item.from,
                availableVersion: item.to, source: .cask(token: item.name), origin: .brew,
                releaseNotes: item.releaseNotes, bundleIdentifier: check.bundleIdentifier,
                completionRequirement: requirement, caskPolicyToken: item.name
            )
        }
    }

    private static func resolvedInstallation(
        token: String, appPaths: [String: URL], checks: [InstallationCheck]
    ) -> InstallationCheck? {
        if let path = appPaths[token], path.isFileURL {
            return checks.last { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) }
        }
        let owners = checks.filter { $0.caskToken == token && $0.unconfirmedCaskToken == nil }
        guard Set(owners.map { InstallationIdentity(path: $0.path) }).count == 1 else { return nil }
        return owners.last
    }
}
