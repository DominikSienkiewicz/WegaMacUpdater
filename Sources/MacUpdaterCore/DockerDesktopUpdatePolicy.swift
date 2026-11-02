import Foundation

/// Docker Desktop owns its default update flow; Homebrew requires a supervised choice.
public enum DockerDesktopUpdatePolicy {
    public static func isDocker(token: String) -> Bool {
        let name = token.split(separator: "/").last.map(String.init)
        return name == "docker" || name == "docker-desktop"
    }

    public static func isDocker(_ item: ManualOutdatedApp) -> Bool {
        if item.bundleIdentifier == "com.docker.docker" { return true }
        if let token = item.caskPolicyToken, isDocker(token: token) { return true }
        if case .cask(let token) = item.source { return isDocker(token: token) }
        return false
    }

    public static func homebrewToken(for item: ManualOutdatedApp) -> String? {
        if case .cask(let token) = item.source, isDocker(token: token) { return token }
        if let token = item.caskPolicyToken, isDocker(token: token) { return token }
        return nil
    }

    public static func batchItems(_ items: [OutdatedItem]) -> [OutdatedItem] {
        items.filter { $0.kind != .cask || !isDocker(token: $0.name) }
    }

    public static func eligibleKeys(_ keys: Set<String>) -> Set<String> {
        keys.filter { !$0.hasPrefix("c:") || !isDocker(token: String($0.dropFirst(2))) }
    }

    /// Only a resolved local installation can become an actionable vendor handoff.
    public static func managedUpdates(
        items: [OutdatedItem], appPaths: [String: URL], installationChecks: [InstallationCheck]
    ) -> [ManualOutdatedApp] {
        items.compactMap { item in
            guard item.kind == .cask, isDocker(token: item.name),
                  let path = appPaths[item.name], path.isFileURL else { return nil }
            let check = installationChecks.last { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) }
            return vendorUpdate(ManualOutdatedApp(
                name: "Docker Desktop", path: path, installedVersion: check?.version ?? item.from,
                availableVersion: item.to, source: .cask(token: item.name), origin: .brew,
                releaseNotes: item.releaseNotes, bundleIdentifier: check?.bundleIdentifier,
                caskPolicyToken: item.name
            ))
        }
    }

    /// Retains the cask's exact build when supplied, including for restored scan snapshots.
    public static func vendorUpdate(_ item: ManualOutdatedApp) -> ManualOutdatedApp {
        guard case .cask(let token) = item.source, isDocker(token: token),
              item.completionRequirement == nil, let version = item.availableVersion else { return item }
        var routed = item
        let variants = versionVariants(version)
        if variants.count > 1, let build = variants.last, !build.isEmpty, build.allSatisfy(\.isNumber) {
            routed.completionRequirement = .init(version: build, field: .buildVersion, scheme: .numericBuild)
        } else if let version = variants.first {
            routed.completionRequirement = .init(version: version)
        }
        return routed
    }
}
