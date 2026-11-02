import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Foreground Mac App Store installation evidence")
@MainActor
struct MasInstallationEvidenceForegroundTests {
    @Test(arguments: [false, true])
    func installedIdentityControlsThePersistedStatus(listFails: Bool) async throws {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Local name.app"), name: "Local name",
                                  bundleIdentifier: "com.example.store", version: "1.0", installDate: nil, updateDate: nil,
                                  isManagedByBrew: false, isManagedByMas: true)
        let check = InstallationCheck(app: app, sources: [], checkedAt: Date())
        let runner = ScanStoreRuntimeProcessRunner { request in
            if request.executableURL.lastPathComponent == "mdls" {
                return ProcessResult(exitCode: 0, stdout: "123", stderr: "")
            }
            switch request.arguments {
            case ["list"]:
                if listFails { throw CocoaError(.fileReadUnknown) }
                return ProcessResult(exitCode: 0, stdout: "123 Store name (1.0)", stderr: "")
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
            case ["outdated", "-g", "--json"]:
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            default:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
        let operations = OperationCoordinator()
        let dependencies = ScanStoreDependencies(
            operations: operations, upgrades: UpgradeCoordinator(operations: operations),
            caskAppPathResolver: CaskAppPathResolver(), bundleExists: { _ in true },
            manualScan: { _, _ in ([], 0) }, reportWindowScan: { _, _, _ in },
            recordUpdateRun: { _ in }, settleAppManagementPermission: { _ in }, undoableUpdates: { [] },
            detailedManualScan: { _, _ in ManualScanReport(apps: [], failedChecks: 0, installations: [check]) }
        )
        let snapshots = ScanStoreRuntimeSnapshotIO()
        let store = ScanStore(resultStore: ScanResultStore(io: snapshots), dependencies: dependencies)
        let tool = URL(fileURLWithPath: "/usr/bin/true")
        let locator = BinaryLocator(brewCandidates: [tool], masCandidates: [tool])
        store.attach(model: AppViewModel(brewService: BrewService(locator: locator, runner: runner),
                                        masService: MasService(locator: locator, runner: runner),
                                        npmService: NpmGlobalService(locator: NpmLocator(extraCandidates: [tool], runner: runner), runner: runner)))

        await store.runCheck(lightweight: true)

        let expected: InstallationCheckStatus = listFails ? .failed : .current
        #expect(store.installationChecks.first?.status(for: app) == expected)
        #expect(store.failedSources == (listFails ? 1 : 0))
        #expect(store.confirmedSourceKinds.contains(.appStore) == !listFails)
        let data = try #require(snapshots.data)
        let snapshot = try JSONDecoder().decode(ScanSnapshot.self, from: data)
        #expect(snapshot.installationChecks.first?.status(for: app) == expected)
        #expect(snapshot.sources.mas?.didFail == listFails)
    }
}
