import Foundation

/// A local installation whose exact-path App Store identity agrees with `mas list`.
public struct MasInstallationEvidence: Equatable, Sendable {
    public let installation: InstallationCheck
    public let appStoreID: String

    public init(installation: InstallationCheck, appStoreID: String) {
        self.installation = installation
        self.appStoreID = appStoreID
    }

    func matches(_ check: InstallationCheck) -> Bool {
        InstallationIdentity(path: installation.path) == InstallationIdentity(path: check.path)
            && installation.bundleIdentifier == check.bundleIdentifier
            && installation.version == check.version
            && installation.buildVersion == check.buildVersion
    }

    static func sourceCheck(
        for check: InstallationCheck,
        evidence: [Self],
        outdated: [MasOutdatedApp]
    ) -> InstallationSourceCheck {
        let unknown = InstallationSourceCheck(source: "App Store", outcome: .notChecked)
        let candidates = evidence.filter { $0.matches(check) }
        guard candidates.count == 1, let identified = candidates.first,
              evidence.filter({ $0.appStoreID == identified.appStoreID }).count == 1 else { return unknown }
        let pending = outdated.filter { $0.appStoreID == identified.appStoreID }
        guard !pending.isEmpty else { return InstallationSourceCheck(source: "App Store", outcome: .current) }
        guard pending.count == 1, let update = pending.first,
              let installedVersion = check.version, !installedVersion.isEmpty,
              update.installedVersion == installedVersion else { return unknown }
        return InstallationSourceCheck(source: "App Store", outcome: .outdated, availableVersion: update.currentVersion,
                                       policyKey: UpdatePlanner.key(name: identified.appStoreID, kind: .appStore))
    }
}
