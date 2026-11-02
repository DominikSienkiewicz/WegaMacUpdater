import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Docker Desktop background shutdown gate", .serialized)
@MainActor
struct DockerDesktopBackgroundGateTests {
    @Test func unattendedBrewMutationRequiresConfirmedDockerShutdown() async {
        let token = "docker-desktop"
        let app = URL(fileURLWithPath: "/TestApplications/Docker.app")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docker-background-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let dependencies = BackgroundUpdater.Dependencies(
            optedInTokens: { [token] }, allowsRound: { true },
            loadPreflight: { _ in BackgroundUpdatePreflight(
                profiles: [.init(token: token, artifacts: [.init(kind: .app, names: ["Docker.app"])])],
                downloads: [.init(token: token, url: "https://example.test/docker.zip", sha256: "abc")],
                appPaths: [token: app]
            ) },
            runningTokens: { _ in [] }, probeDownloadSizes: { _, _ in [token: .known(bytes: 1)] },
            performWrite: { await $0() }, acquireMutex: { true }, releaseMutex: {}, policies: { [:] },
            resourceDecision: { _, _, _ in .allow }, publisherVetoes: { _, _ in [:] },
            beginOperation: { store.begin(trigger: .background) },
            snapshot: { _, _, operation in
                operation.recordSnapshotted(token: token, snapshotName: "Docker.app")
                return [token: operation.snapshotsDirectory.appendingPathComponent("Docker.app")]
            },
            removeOperation: { store.removeOperation(id: $0) },
            runBrew: { _ in
                Issue.record("Background update must not run Brew after unconfirmed Docker shutdown")
                return BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])
            },
            recordAppManagementDenial: {}, clearAppManagementDenial: {},
            verify: { _, _, _, _ in [token: .healthy] },
            outdatedGreedy: { BrewOutdated(formulae: [], casks: []) }, notify: { _ in },
            stopDocker: { _ in .timedOut }
        )

        let upgraded = await BackgroundUpdater(dependencies: dependencies).runIfEligible(candidates: [token], policies: [:])

        #expect(upgraded.isEmpty)
    }
}
