import Foundation

/// Detects Homebrew cask "metadata drift" — casks whose real on-disk app
/// version already matches (or exceeds) `current_version`, even though brew
/// still records an older `installed_versions`. Happens for apps with built-in
/// self-updaters (Google Chrome, Edge, Brave, Firefox, ...) that rewrite their
/// bundle outside of Homebrew, leaving brew's metadata stale.
public struct BrewCaskDriftFilter {
    private let applicationsDir: URL
    private let userApplicationsDir: URL
    private let readBundleVersion: (URL) -> String?

    public init(
        applicationsDir: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        userApplicationsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true),
        readBundleVersion: @escaping (URL) -> String? = BrewCaskDriftFilter.readBundleShortVersionString
    ) {
        self.applicationsDir = applicationsDir
        self.userApplicationsDir = userApplicationsDir
        self.readBundleVersion = readBundleVersion
    }

    /// Returns tokens whose real bundle version already matches or exceeds
    /// `currentVersion` and should therefore be hidden from the outdated list.
    public func driftedTokens(
        outdated: [BrewOutdatedItem],
        installationInfo: [BrewCaskInstallationInfo]
    ) -> Set<String> {
        let infoByToken = Dictionary(installationInfo.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        var drifted: Set<String> = []

        for item in outdated {
            guard let current = item.currentVersion,
                  let info = infoByToken[item.name],
                  !info.appArtifacts.isEmpty else { continue }

            for artifact in info.appArtifacts {
                let candidates = [
                    applicationsDir.appendingPathComponent(artifact),
                    userApplicationsDir.appendingPathComponent(artifact)
                ]
                guard let realVersion = candidates.lazy.compactMap(readBundleVersion).first else { continue }

                if versionsEqual(realVersion, current) || isUpgrade(installed: current, latest: realVersion) {
                    drifted.insert(item.name)
                    break
                }
            }
        }
        return drifted
    }

    public static func readBundleShortVersionString(_ appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else { return nil }
        return version
    }
}
