import Foundation

struct ManualCheckObservation: Sendable {
    let app: ApplicationInfo
    let source: String
    let result: ManualCheckResult
    var wasApplicable = false
}

public struct ManualScanReport: Sendable {
    public var apps: [ManualOutdatedApp]
    public var failedChecks: Int
    public var uncheckedSources: [String]
    public var installations: [InstallationCheck]

    public init(apps: [ManualOutdatedApp], failedChecks: Int, uncheckedSources: [String] = [], installations: [InstallationCheck] = []) {
        self.apps = apps
        self.failedChecks = failedChecks
        self.uncheckedSources = uncheckedSources
        self.installations = installations
    }

    init(apps: [ManualOutdatedApp], observations: [ManualCheckObservation], installations: [ApplicationInfo], checkedAt: Date) {
        let unavailable = observations.filter { $0.result == .failed || $0.result == .unavailable }
        self.init(apps: apps, failedChecks: unavailable.count,
                  uncheckedSources: unavailable.map { "\($0.source) · \($0.app.name)" }.sorted())
        let byPath = Dictionary(grouping: observations, by: { $0.app.installation })
        self.installations = installations.map { app in
            let sources = (byPath[app.installation] ?? [])
                .filter { $0.result != .notApplicable || $0.wasApplicable }
                .map { InstallationSourceCheck(source: $0.source, result: $0.result) }
                .sorted { $0.source < $1.source }
            return InstallationCheck(app: app, sources: sources, checkedAt: checkedAt)
        }
    }

    public var sourceReport: ScanSourceReport {
        guard failedChecks > 0 else { return ScanSourceReport(outcome: .succeeded) }
        return ScanSourceReport(outcome: .failed("manual"),
                                error: uncheckedSources.isEmpty ? "manual: \(failedChecks)" : uncheckedSources.joined(separator: ", "))
    }
}
