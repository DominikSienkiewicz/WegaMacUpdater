import Foundation
import WegaHelperKit

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
        applicationsDir: URL = SystemPaths.applicationsDirectory,
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
    ///
    /// - Parameter attributedInstallations: the scan's installations. A cask that declares
    ///   no `.app` (an installer script or a `pkg`, such as Logi Options+) is judged by the
    ///   copies the scan confirmed as its own; every one of them must be current.
    public func driftedTokens(
        outdated: [BrewOutdatedItem],
        installationInfo: [BrewCaskInstallationInfo],
        attributedInstallations: [InstallationCheck] = []
    ) -> Set<String> {
        let infoByToken = Dictionary(installationInfo.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        var drifted: Set<String> = []

        for item in outdated {
            guard let current = item.currentVersion, let info = infoByToken[item.name] else { continue }
            let isCurrentOnDisk = info.appArtifacts.isEmpty
                ? Self.attributedCopiesAreCurrent(token: item.name, current: current, installations: attributedInstallations)
                : someAppArtifactIsCurrent(info.appArtifacts, current: current)
            if isCurrentOnDisk { drifted.insert(item.name) }
        }
        return drifted
    }

    private func someAppArtifactIsCurrent(_ artifacts: [String], current: String) -> Bool {
        artifacts.contains { artifact in
            let candidates = [
                applicationsDir.appendingPathComponent(artifact),
                userApplicationsDir.appendingPathComponent(artifact)
            ]
            guard let realVersion = candidates.lazy.compactMap(readBundleVersion).first else { return false }
            return versionAtLeast(realVersion, current)
        }
    }

    private static func attributedCopiesAreCurrent(
        token: String, current: String, installations: [InstallationCheck]
    ) -> Bool {
        let owned = installations.filter { $0.caskToken == token }
        return !owned.isEmpty && owned.allSatisfy { copy in
            copy.version.map { versionAtLeast($0, current) } ?? false
        }
    }

    public static func readBundleShortVersionString(_ appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else { return nil }
        return version
    }
}
