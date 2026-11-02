import Foundation
import MacUpdaterCore
import XCTest
@testable import WegaMacUpdater

private actor DockerGateStopRecorder {
    private(set) var paths: [URL] = []
    var results: [DockerDesktopStopResult]

    init(_ results: [DockerDesktopStopResult] = [.timedOut]) { self.results = results }

    func stop(_ path: URL) -> DockerDesktopStopResult {
        paths.append(path)
        return results.isEmpty ? .timedOut : results.removeFirst()
    }
}

@MainActor
final class DockerDesktopMutationGateTests: XCTestCase {
    private let token = "docker-desktop"
    private let appURL = URL(fileURLWithPath: "/TestApplications/Docker.app")

    func testForegroundUpgradeDoesNotInvokeBrewWhenShutdownIsUnconfirmed() async {
        let runner = inertRunner()
        let recorder = DockerGateStopRecorder()
        let store = scanStore(runner: runner, recorder: recorder)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = UpdateOperationStore(rootDirectory: root).begin(trigger: .manual)
        let item = OutdatedItem(key: "c:\(token)", name: token, from: "1", to: "2", kind: .cask)

        let result = await store.upgradeOneCask(item: item, appPaths: [token: appURL], snapshots: [:], operation: operation)

        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertEqual(result.outcome?.isSuccessful, false)
        let stoppedPaths = await recorder.paths
        XCTAssertEqual(stoppedPaths, [appURL])
    }

    func testManualAdoptionAndReinstallStopBeforePreparingOrExecutingBrew() async {
        for reinstall in [false, true] {
            let runner = inertRunner()
            let recorder = DockerGateStopRecorder()
            let store = scanStore(runner: runner, recorder: recorder)
            store.manualOutdated = [ManualOutdatedApp(
                name: "Docker", path: appURL, installedVersion: "1", availableVersion: "2",
                source: .cask(token: token), bundleIdentifier: "com.docker.docker"
            )]

            if reinstall { await store.reinstallManual(token: token) }
            else { await store.installManual(token: token) }

            XCTAssertTrue(runner.requests.isEmpty)
            let stoppedPaths = await recorder.paths
            XCTAssertEqual(stoppedPaths, [appURL])
            XCTAssertEqual(store.banner?.variant, .danger)
        }
    }

    func testExplicitBrewActionFindsDockerRowsWithExistingVendorEvidence() async {
        for policyToken in ["docker", "docker-desktop", "homebrew/cask/docker-desktop"] {
            let runner = inertRunner()
            let recorder = DockerGateStopRecorder()
            let store = scanStore(runner: runner, recorder: recorder)
            store.manualOutdated = [ManualOutdatedApp(
                name: "Docker", path: appURL, installedVersion: "1", availableVersion: "2",
                source: .sparkle, bundleIdentifier: "com.docker.docker", caskPolicyToken: policyToken
            )]

            await store.installManual(token: token)

            let stoppedPaths = await recorder.paths
            XCTAssertEqual(stoppedPaths, [appURL])
            XCTAssertTrue(runner.requests.isEmpty)
            XCTAssertEqual(store.manualOutdated.first?.source, .sparkle)
        }
    }

    func testMigrationStopsBeforePreparationWhenDockerCannotShutDown() async {
        let recorder = DockerGateStopRecorder()
        var dependencies = MigrationStore.Dependencies.live
        dependencies.stopDocker = { await recorder.stop($0) }
        dependencies.prepareReplacement = { _, _, _ in
            XCTFail("Docker migration must stop before preparing a replacement after shutdown failure")
            return .snapshotFailed
        }
        let store = MigrationStore(
            runningApplicationInspector: ScanStoreRuntimeApplicationInspector(),
            publisherCorrelator: CaskPublisherCorrelator(
                expectedTeamIDForCask: { _ in nil }, installedTeamIDForApp: { _ in nil }
            ),
            dependencies: dependencies
        )
        let app = ApplicationInfo(
            path: appURL, name: "Docker", bundleIdentifier: "com.docker.docker", version: "1",
            installDate: nil, updateDate: nil, isManagedByBrew: false,
            caskToken: token, caskMatchProvenance: .token
        )
        await store.migrate(app, model: model(runner: inertRunner()), onWegaState: nil)

        let stoppedPaths = await recorder.paths
        XCTAssertEqual(stoppedPaths, [appURL])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.migrated.isEmpty)
    }

    func testForcedRetryRechecksShutdownBeforeReplacingTheBundleAgain() async {
        let runner = ScanStoreRuntimeProcessRunner(run: { _ in
            ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }, events: { _ in
            .success([
                .stderr("Error: docker-desktop: It seems there is already an App at '/Applications/Docker.app'\n"),
                .finished(ProcessResult(exitCode: 1, stdout: "", stderr: "")),
            ])
        })
        let recorder = DockerGateStopRecorder([.stopped, .timedOut])
        let store = scanStore(runner: runner, recorder: recorder)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = UpdateOperationStore(rootDirectory: root).begin(trigger: .manual)
        let item = OutdatedItem(key: "c:\(token)", name: token, from: "1", to: "2", kind: .cask)

        let result = await store.upgradeOneCask(item: item, appPaths: [token: appURL], snapshots: [:], operation: operation)

        XCTAssertEqual(runner.requests.count, 1)
        XCTAssertFalse(runner.requests.contains { $0.arguments.contains("--force") })
        let stoppedPaths = await recorder.paths
        XCTAssertEqual(stoppedPaths, [appURL, appURL])
        XCTAssertEqual(result.outcome?.isSuccessful, false)
    }

    func testAStaleForceTerminationRequestStillUsesControlledDockerShutdown() async {
        let recorder = DockerGateStopRecorder()
        let runner = inertRunner()
        var dependencies = MigrationStore.Dependencies.live
        dependencies.stopDocker = { await recorder.stop($0) }
        dependencies.prepareReplacement = { _, _, _ in .snapshotFailed }
        let app = ApplicationInfo(
            path: appURL, name: "Docker", bundleIdentifier: "com.docker.docker", version: "1",
            installDate: nil, updateDate: nil, isManagedByBrew: false,
            caskToken: token, caskMatchProvenance: .token
        )
        let target = RunningApplicationTarget(
            processIdentifier: 98765, bundleURL: appURL, bundleIdentifier: "com.docker.docker",
            appName: "Docker", processName: "Docker"
        )
        let store = MigrationStore(
            processes: RunningProcessService(runner: runner),
            runningApplicationInspector: ScanStoreRuntimeApplicationInspector(applications: [target]),
            dependencies: dependencies
        )

        await store.forceTerminateAndMigrate(PendingForceTermination(app: app, target: target), model: model(runner: runner), onWegaState: nil)

        let stoppedPaths = await recorder.paths
        XCTAssertEqual(stoppedPaths, [appURL])
        XCTAssertFalse(runner.requests.contains { $0.arguments.contains("-KILL") })
    }

    private func scanStore(runner: ScanStoreRuntimeProcessRunner, recorder: DockerGateStopRecorder) -> ScanStore {
        var dependencies = ScanStoreDependencies.live
        dependencies.stopDocker = { await recorder.stop($0) }
        let store = ScanStore(resultStore: ScanResultStore(io: ScanStoreRuntimeSnapshotIO()), dependencies: dependencies)
        store.attach(model: model(runner: runner))
        return store
    }

    private func model(runner: ScanStoreRuntimeProcessRunner) -> AppViewModel {
        AppViewModel(brewService: BrewService(locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/bin/echo")]), runner: runner))
    }

    private func inertRunner() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner { _ in ProcessResult(exitCode: 0, stdout: #"{"casks":[]}"#, stderr: "") }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("docker-gate-tests-\(UUID().uuidString)")
    }
}
