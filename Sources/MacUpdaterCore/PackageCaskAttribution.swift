import Foundation

/// Exact ownership for reporting; these paths do not authorize bundle replacement or rollback.
struct PackageCaskAttribution {
    let installations: [ApplicationInfo]
    let paths: [String: URL]
    let unconfirmedCandidates: [InstallationIdentity: String]

    static func resolve(
        installations: [ApplicationInfo], casks: [BrewCask], installedTokens: Set<String>,
        receiptLocator: PackageReceiptLocator
    ) async -> Self {
        let packageCasks = casks.filter {
            installedTokens.contains($0.token) && (!$0.pkgutilIdentifiers.isEmpty || !$0.uninstallAppPaths.isEmpty)
        }
        let packageTokens = Set(packageCasks.map(\.token))
        var tokensByReceipt: [String: Set<String>] = [:]
        var tokensByPath: [InstallationIdentity: Set<String>] = [:]
        for cask in packageCasks {
            for identifier in cask.pkgutilIdentifiers { tokensByReceipt[identifier, default: []].insert(cask.token) }
            for path in cask.uninstallAppPaths { tokensByPath[InstallationIdentity(path: path), default: []].insert(cask.token) }
        }
        var claims: [String: [InstallationIdentity: URL]] = [:]
        var unambiguousInstallations = Set<InstallationIdentity>()
        for app in installations where !app.isManagedByMas {
            var tokens = tokensByPath[app.installation] ?? []
            if !tokensByReceipt.isEmpty {
                let identifiers = await receiptLocator.packageIdentifiers(forBundleAt: app.path)
                for identifier in identifiers { tokens.formUnion(tokensByReceipt[identifier] ?? []) }
            }
            if tokens.count == 1 { unambiguousInstallations.insert(app.installation) }
            for token in tokens { claims[token, default: [:]][app.installation] = app.path }
        }
        let paths = claims.compactMapValues { claimed -> URL? in
            guard claimed.count == 1, let (installation, path) = claimed.first,
                  unambiguousInstallations.contains(installation) else { return nil }
            return path
        }
        let owners = UpdatePlanner.resolvedCaskPolicyTokens(appPaths: paths)
        var unconfirmedCandidates: [InstallationIdentity: String] = [:]
        let attributed = installations.map { app in
            var attributed = app
            if !app.isManagedByMas, let token = owners[app.installation] {
                if attributed.caskToken != token { attributed.caskMatchProvenance = nil }
                attributed.caskToken = token
                attributed.isManagedByBrew = true
            } else if app.isManagedByMas || app.caskToken.map({ packageTokens.contains($0) }) == true {
                if !app.isManagedByMas, let token = app.caskToken { unconfirmedCandidates[app.installation] = token }
                attributed.caskToken = nil
                attributed.caskMatchProvenance = nil
                attributed.isManagedByBrew = false
            }
            return attributed
        }
        return Self(installations: attributed, paths: paths, unconfirmedCandidates: unconfirmedCandidates)
    }
}
