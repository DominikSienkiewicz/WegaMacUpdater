import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Exact Mac App Store installation evidence")
struct MasInstallationEvidenceTests {
    private let time = Date(timeIntervalSince1970: 1000)
    private var app: ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Renamed.app"), name: "Local name",
                        bundleIdentifier: "com.example.store", version: "1.0", buildVersion: "100",
                        installDate: nil, updateDate: nil, isManagedByBrew: false, isManagedByMas: true)
    }
    private var record: InstallationCheck { InstallationCheck(app: app, sources: [], checkedAt: time) }
    private var reports: ScanSourceReports { ScanSourceReports(mas: .init(outcome: .succeeded)) }
    private var evidence: MasInstallationEvidence { MasInstallationEvidence(installation: record, appStoreID: "123") }
    private var update: MasOutdatedApp {
        MasOutdatedApp(appStoreID: "123", name: "Different store name", installedVersion: "1.0", currentVersion: "2.0")
    }

    @Test func identifiedInstalledCopyIsCurrentAfterSuccessfulScanWithNoPendingUpdate() {
        let result = InstallationCheck.resolvingManagers([record], reports: reports, brew: nil, mas: [], masEvidence: [evidence])
        #expect(result.first?.status(for: app, now: time) == .current)
        #expect(result.first?.lastSuccessfulCheck == time)
    }

    @Test func updateUsesExactStoreIDAndCarriesVersionAndPolicy() {
        let result = InstallationCheck.resolvingManagers([record], reports: reports, brew: nil, mas: [update], masEvidence: [evidence])
        #expect(result.first?.status(for: app, now: time) == .updateAvailable)
        #expect(result.first?.sources == [.init(source: "App Store", outcome: .outdated, availableVersion: "2.0", policyKey: "a:123")])
        #expect(result.first?.status(for: app, policies: ["a:123": .skipped(version: "2.0")], now: time) == .excluded)
    }

    @Test func outdatedAbsenceAloneCannotConfirmAnUnidentifiedCopy() {
        let result = InstallationCheck.resolvingManagers([record], reports: reports, brew: nil, mas: [], masEvidence: [])
        #expect(result.first?.status(for: app, now: time) == .notChecked)
        #expect(result.first?.lastSuccessfulCheck == nil)
    }

    @Test func unavailableOrFailedSourceCannotReuseEarlierCurrentEvidence() {
        let old = InstallationCheck(app: app, sources: [.init(source: "App Store", outcome: .current)], checkedAt: time)
        for outcome in [SourceCheckOutcome.notInstalled, .failed("mas list")] {
            let result = InstallationCheck.resolvingManagers([old], reports: .init(mas: .init(outcome: outcome)),
                                                             brew: nil, mas: [], masEvidence: [evidence])
            #expect(result.first?.status(for: app, now: time) == (outcome == .notInstalled ? .notChecked : .failed))
        }
    }

    @Test func anotherPathOrChangedBundleCannotReceiveThisEvidence() {
        var another = app
        another.path = URL(fileURLWithPath: "/Users/test/Applications/Renamed.app")
        var changed = app
        changed.bundleIdentifier = "com.example.replacement"
        for candidate in [another, changed] {
            let check = InstallationCheck(app: candidate, sources: [], checkedAt: time)
            let result = InstallationCheck.resolvingManagers([check], reports: reports, brew: nil, mas: [], masEvidence: [evidence])
            #expect(result.first?.status(for: candidate, now: time) == .notChecked)
        }
    }

    @Test func duplicatedOrVersionMismatchedUpdateCannotConfirmThisCopy() {
        var changed = update
        changed.installedVersion = "0.9"
        for pending in [[update, update], [changed]] {
            let result = InstallationCheck.resolvingManagers([record], reports: reports, brew: nil, mas: pending, masEvidence: [evidence])
            #expect(result.first?.status(for: app, now: time) == .notChecked)
            #expect(result.first?.lastSuccessfulCheck == nil)
        }
    }

    @Test func duplicateIdentitiesCannotAssignOneManagerResultToTwoCopies() {
        var other = app
        other.path = URL(fileURLWithPath: "/Users/test/Applications/Renamed.app")
        let otherCheck = InstallationCheck(app: other, sources: [], checkedAt: time)
        let duplicate = MasInstallationEvidence(installation: otherCheck, appStoreID: "123")
        let result = InstallationCheck.resolvingManagers([record, otherCheck], reports: reports, brew: nil,
                                                         mas: [], masEvidence: [evidence, duplicate])
        #expect(result.map { $0.sources.first?.outcome } == [.notChecked, .notChecked])
    }
}
