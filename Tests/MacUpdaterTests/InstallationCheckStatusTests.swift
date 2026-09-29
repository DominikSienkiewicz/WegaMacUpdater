import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Installation check status")
struct InstallationCheckStatusTests {
    private let time = Date(timeIntervalSince1970: 1000)
    private var app: ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                        bundleIdentifier: "com.example.app", version: "1.0", buildVersion: "100",
                        installDate: nil, updateDate: nil, isManagedByBrew: false, caskToken: nil)
    }

    @Test func aTemporaryOutageCannotBecomeCurrentEvenWhenAnotherSourceSucceeded() {
        let observations = [
            ManualCheckObservation(app: app, source: "Sparkle", result: .unavailable),
            ManualCheckObservation(app: app, source: "GitHub", result: .upToDate),
            ManualCheckObservation(app: app, source: "Adobe", result: .notApplicable)
        ]
        let report = ManualScanReport(apps: [], observations: observations, installations: [app], checkedAt: time)
        #expect(report.failedChecks == 1)
        #expect(report.uncheckedSources == ["Sparkle · Example"])
        #expect(report.sourceReport.didFail)
        #expect(report.installations.first?.status(for: app, now: time) == .failed)
        #expect(report.installations.first?.lastSuccessfulCheck == nil)
    }

    @Test func unknownAndUnobservedAppsAreNeverCurrent() {
        let unknown = InstallationCheck(app: app, sources: [], checkedAt: time)
        #expect(unknown.status(for: app, now: time) == .noSource)
        let unchecked = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .notChecked)], checkedAt: time)
        #expect(unchecked.status(for: app, now: time) == .notChecked)
        let knownButIncomparable = ManualScanReport(
            apps: [], observations: [ManualCheckObservation(app: app, source: "Sparkle", result: .notApplicable, wasApplicable: true)],
            installations: [app], checkedAt: time
        )
        #expect(knownButIncomparable.installations.first?.status(for: app, now: time) == .notChecked)
        #expect(knownButIncomparable.failedChecks == 0)
    }

    @Test func policiesHideOnlyTheOfferedUpdateOfThisCopy() {
        let update = ManualOutdatedApp(name: app.name, path: app.path, installedVersion: "1.0", availableVersion: "2.0",
                                       source: .sparkle, bundleIdentifier: app.bundleIdentifier)
        let record = InstallationCheck(app: app, sources: [.init(source: "Sparkle", result: .outdated(update))], checkedAt: time)
        #expect(record.status(for: app, now: time) == .updateAvailable)
        #expect(record.status(for: app, policies: [update.policyKey: .skipped(version: "2.0")], now: time) == .excluded)
        var otherCopy = app
        otherCopy.path = URL(fileURLWithPath: "/Users/test/Applications/Example.app")
        #expect(record.status(for: otherCopy, now: time) == .notChecked)
    }

    @Test func changedVersionAndOldRecordsAreStaleWhileReplacedBundlesAreUnobserved() {
        let record = InstallationCheck(app: app, sources: [.init(source: "Sparkle", outcome: .current)], checkedAt: time)
        #expect(record.status(for: app, now: time) == .current)
        #expect(record.status(for: app, now: time.addingTimeInterval(86_401)) == .stale)
        var changed = app
        changed.buildVersion = "101"
        #expect(record.status(for: changed, now: time) == .stale)
        changed.bundleIdentifier = "com.other.app"
        #expect(record.status(for: changed, now: time) == .notChecked)
    }

    @Test func failurePreservesTheLastSuccessfulCheckAndRoundTripsInTheSnapshot() throws {
        let success = InstallationCheck(app: app, sources: [.init(source: "Sparkle", outcome: .current)], checkedAt: time)
        let failed = InstallationCheck(app: app, sources: [.init(source: "Sparkle", outcome: .failed)], checkedAt: time.addingTimeInterval(60))
        let retained = InstallationCheck.retainingLastSuccess([failed], previous: [success])
        #expect(retained.first?.lastSuccessfulCheck == time)
        let snapshot = ScanSnapshot(scannedAt: time, brew: nil, mas: [], npm: [], manual: [], installationChecks: retained)
        let restored = try JSONDecoder().decode(ScanSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.installationChecks == retained)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        legacy.removeValue(forKey: "installationChecks")
        let old = try JSONDecoder().decode(ScanSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.installationChecks.isEmpty)
    }

    @Test func managerFailureAndUnknownTargetNeverBecomeCurrent() {
        var record = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .notChecked)], checkedAt: time)
        record.caskToken = "example"
        let pending = BrewOutdated(formulae: [], casks: [
            BrewOutdatedItem(name: "example", installedVersions: ["1"], currentVersion: nil)
        ])
        let success = ScanSourceReports(brew: .init(outcome: .succeeded))
        let resolved = InstallationCheck.resolvingManagers([record], reports: success, brew: pending)
        #expect(resolved.first?.status(for: app, now: time) == .updateAvailable)
        let offline = ScanSourceReports(brewMetadata: .init(outcome: .failed("refresh")), brew: .init(outcome: .succeeded))
        let failed = InstallationCheck.resolvingManagers([record], reports: offline, brew: nil)
        #expect(failed.first?.status(for: app, now: time) == .failed)
        #expect(failed.first?.lastSuccessfulCheck == nil)
    }

    @Test func completingABackgroundUpgradeInvalidatesItsOldInstallationEvidence() {
        var record = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .outdated)], checkedAt: time)
        record.caskToken = "example"
        let pending = BrewOutdated(formulae: [], casks: [BrewOutdatedItem(name: "example", installedVersions: ["1"], currentVersion: "2")])
        let result = MenuBarScanResult(brew: pending, mas: [], npm: [], manualApps: [], failedChecks: 0, scannedAt: time,
                                       total: 1, installationChecks: [record])
        #expect(result.removingUpgradedCasks(["example"]).installationChecks.isEmpty)
    }
}
