import Foundation

public extension MicrosoftAutoUpdateReport {
    /// The listing identifies a product, not its registered path. Missing offers never certify a copy as current.
    func applying(to report: ManualScanReport, applications: [ApplicationInfo]) -> ManualScanReport {
        var updated = report
        let byPath = Dictionary(applications.map { ($0.installation, $0) }, uniquingKeysWith: { first, _ in first })
        for index in updated.installations.indices {
            let installation = updated.installations[index]
            guard let app = byPath[InstallationIdentity(path: installation.path)],
                  app.bundleIdentifier == installation.bundleIdentifier,
                  let applicationID = MicrosoftAutoUpdateSupport.applicationID(for: app) else { continue }
            let result = check(app: app)
            updated.installations[index].sources.removeAll { $0.source == MicrosoftAutoUpdateSupport.sourceLabel }
            updated.installations[index].sources.append(.init(source: MicrosoftAutoUpdateSupport.sourceLabel, result: result))
            updated.installations[index].microsoftAutoUpdate = .init(applicationID: applicationID, status: status,
                updaterVersion: updaterVersion)
            updated.installations[index].lastSuccessfulCheck = nil
            updated.installations[index].stampSuccess()
            switch result {
            case .outdated(var item):
                item.caskPolicyToken = installation.caskToken
                updated.apps.append(item)
            case .failed, .unavailable:
                updated.failedChecks += 1
                updated.uncheckedSources.append(MicrosoftAutoUpdateSupport.sourceLabel + " · " + app.name)
            case .notApplicable, .upToDate: break
            }
        }
        updated.apps = UpdatePlanner.dedupedByPriority(updated.apps)
        updated.uncheckedSources.sort()
        return updated
    }
}
