import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Menu bar Mac App Store installation evidence")
struct MasInstallationEvidenceMenuBarTests {
    @Test func successfulBackgroundScanConfirmsTheIdentifiedInstallation() async {
        let app = makeApp()
        let check = InstallationCheck(app: app, sources: [], checkedAt: Date())
        let result = await checker(check: check, failIdentity: false).availableUpdateCount()
        #expect(result.installationChecks.first?.status(for: app) == .current)
        #expect(result.installationChecks.first?.lastSuccessfulCheck != nil)
        #expect(result.failedChecks == 0)
    }

    @Test func installedListFailureStaysFailedAfterAnEmptyOutdatedResult() async {
        let app = makeApp()
        let check = InstallationCheck(app: app, sources: [], checkedAt: Date())
        let result = await checker(check: check, failIdentity: true).availableUpdateCount()
        #expect(result.installationChecks.first?.status(for: app) == .failed)
        #expect(result.sources.mas?.didFail == true)
        #expect(result.failedChecks == 1)
    }

    private func makeApp() -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Store.app"), name: "Store",
                        bundleIdentifier: "com.example.store", version: "1.0", installDate: nil, updateDate: nil,
                        isManagedByBrew: false, isManagedByMas: true)
    }

    private func checker(check: InstallationCheck, failIdentity: Bool) -> MenuBarUpdateChecker {
        MenuBarUpdateChecker(brewService: MasEvidenceEmptyBrew(), masService: MasEvidenceProvider(check: check, failIdentity: failIdentity),
                             npmService: MasEvidenceEmptyNpm(), scanner: MasEvidenceScanner(check: check), operations: OperationCoordinator())
    }
}

private struct MasEvidenceProvider: MasOutdatedProviding {
    let check: InstallationCheck
    let failIdentity: Bool
    func outdated() async throws -> [MasOutdatedApp] { [] }
    func installationEvidence(for installations: [InstallationCheck]) async throws -> [MasInstallationEvidence] {
        if failIdentity { throw CocoaError(.fileReadUnknown) }
        return [MasInstallationEvidence(installation: check, appStoreID: "123")]
    }
}

private struct MasEvidenceEmptyBrew: BrewOutdatedProviding {
    func outdatedGreedy() async throws -> BrewOutdated { BrewOutdated(formulae: [], casks: []) }
}

private struct MasEvidenceEmptyNpm: NpmOutdatedProviding {
    func outdated() async throws -> [NpmGlobalOutdated] { [] }
}

private struct MasEvidenceScanner: ManualScanning {
    let check: InstallationCheck
    func scan(brewOutdatedCasks: Set<String>) async -> (apps: [ManualOutdatedApp], failedChecks: Int) { ([], 0) }
    func scanReport(brewOutdatedCasks: Set<String>) async -> ManualScanReport {
        ManualScanReport(apps: [], failedChecks: 0, installations: [check])
    }
}
