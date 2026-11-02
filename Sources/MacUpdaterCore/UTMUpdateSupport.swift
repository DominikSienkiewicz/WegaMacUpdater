import Foundation

/// Official standalone UTM releases, with App Store and native Sparkle channels preserved.
enum UTMUpdateSupport {
    static let bundleIdentifier = "com.utmapp.UTM"
    static let repository = "utmapp/UTM"
    static let githubEntry = GitHubCatalogEntry(
        bundleId: bundleIdentifier, repo: repository, caskToken: "utm", selfUpdates: false
    )

    static func usesNativeUpdateChannel(_ app: ApplicationInfo, client: HTTPClient) -> Bool {
        guard app.bundleIdentifier == bundleIdentifier else { return false }
        return app.isManagedByMas || app.masAppID != nil
            || SparkleUpdateChecker(client: client).plan(for: app) != nil
    }

    static func comparableMacOSReleases(
        _ releases: [GitHubRelease], installedVersion: String?
    ) -> [GitHubRelease]? {
        guard let installedVersion, isStableVersion(installedVersion) else { return nil }
        let supported = releases.filter { release in
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            return isStableVersion(version) && release.assets?.contains { $0.name == "UTM.dmg" } == true
        }
        return supported.isEmpty ? nil : supported
    }

    private static func isStableVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 3 && components.allSatisfy { component in
            guard let value = Int(component), value >= 0 else { return false }
            return String(value) == component
        }
    }
}
