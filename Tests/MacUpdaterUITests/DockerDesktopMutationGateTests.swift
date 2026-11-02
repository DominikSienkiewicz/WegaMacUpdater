import Foundation
import MacUpdaterCore
import Testing
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

@Suite("Docker Desktop bundle mutation gates", .serialized)
@MainActor
struct DockerDesktopMutationGateTests {
    private let token = "docker-desktop"
    private let appURL = URL(fileURLWithPath: "/TestApplications/Docker.app")

    @Test func foregroundUpgradeDoesNotInvokeBrewWhenShutdownIsUnconfirmed() async {
        let runner = inertRunner()
        let recorder = DockerGateStopRecorder()
        let store = scanStore(runner: runner, recorder: recorder)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = UpdateOperationStore(rootDirectory: root).begin(trigger: .manual)
        let item = OutdatedItem(key: "c:\(token)", name: token, from: "1", to: "2", kind: .cask)

        let result = await store.upgradeOneCask(item: item, appPaths: [token: appURL], snapshots: [:], operation: operation)

        #expect(runner.requests.isEmpty)
        #expect(result.outcome?.isSuccessful == false)
        #expect(await recorder.paths == [appURL])
    }

    @Test(arguments: [false, true])
    func manualAdoptionAndReinstallStopBeforePreparingOrExecutingBrew(reinstall: Bool) async {
        let runner = inertRunner()
        let recorder = DockerGateStopRecorder()
        let store = scanStore(runner: runner, recorder: recorder)
        store.manualOutdated = [ManualOutdatedApp(
            name: "Docker", path: appURL, installedVersion: "1", availableVersion: "2",
            source: .cask(token: token), bundleIdentifier: "com.docker.docker"
        )]

        if reinstall { await store.reinstallManual(token: token) }
        else { await store.installManual(token: token) }

        #expect(runner.requests.isEmpty)
        #expect(await recorder.paths == [appURL])
        #expect(store.banner?.variant == .danger)
    }

    @Test(arguments: ["docker", "docker-desktop", "homebrew/cask/docker-desktop"])
    func explicitBrewActionFindsDockerRowsWithExistingVendorEvidence(policyToken: String) async {
        let runner = inertRunner()
        let recorder = DockerGateStopRecorder()
        let store = scanStore(runner: runner, recorder: recorder)
        store.manualOutdated = [ManualOutdatedApp(
            name: "Docker", path: appURL, installedVersion: "1", availableVersion: "2",
            source: .sparkle, bundleIdentifier: "com.docker.docker", caskPolicyToken: policyToken
        )]

        await store.installManual(token: token)

        #expect(await recorder.paths == [appURL])
        #expect(runner.requests.isEmpty)
        #expect(store.manualOutdated.first?.source == .sparkle)
    }

    @Test func migrationStopsBeforePreparationWhenDockerCannotShutDown() async {
        let recorder = DockerGateStopRecorder()
        var dependencies = MigrationStore.Dependencies.live
        dependencies.stopDocker = { await recorder.stop($0) }
        dependencies.prepareReplacement = { _, _, _ in
            Issue.record("Docker migration must stop before preparing a replacement after shutdown failure")
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

        #expect(await recorder.paths == [appURL])
        #expect(store.errorMessage != nil)
        #expect(store.migrated.isEmpty)
    }

    @Test func forcedRetryRechecksShutdownBeforeReplacingTheBundleAgain() async {
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

        #expect(runner.requests.count == 1)
        #expect(!runner.requests.contains { $0.arguments.contains("--force") })
        #expect(await recorder.paths == [appURL, appURL])
        #expect(result.outcome?.isSuccessful == false)
    }

    @Test func aStaleForceTerminationRequestStillUsesControlledDockerShutdown() async {
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

        #expect(await recorder.paths == [appURL])
        #expect(!runner.requests.contains { $0.arguments.contains("-KILL") })
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
