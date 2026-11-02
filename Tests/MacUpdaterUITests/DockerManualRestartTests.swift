import Foundation
import MacUpdaterCore
import XCTest
@testable import WegaMacUpdater

@MainActor
final class DockerManualRestartTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/TestApplications/Docker.app")

    func testManualDockerInstallationQueuesExplicitRestartWithoutStartingIt() {
        let calls = ManualDockerRestartRecorder()
        let store = makeStore(calls: calls)

        store.queueDockerRestart(token: "homebrew/cask/docker-desktop", bundleURL: bundleURL)

        XCTAssertEqual(store.restartCandidates.count, 1)
        XCTAssertEqual(store.restartCandidates.first?.appName, "Docker")
        let processName = store.restartCandidates.first?.processName ?? "missing"
        XCTAssertEqual(store.restartDockerBundleURLs[processName], bundleURL)
        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertNil(store.restartBusy)
    }

    func testUnrelatedManualInstallationDoesNotQueueDockerRestart() {
        let calls = ManualDockerRestartRecorder()
        let store = makeStore(calls: calls)

        store.queueDockerRestart(token: "example", bundleURL: bundleURL)

        XCTAssertTrue(store.restartCandidates.isEmpty)
        XCTAssertTrue(store.restartDockerBundleURLs.isEmpty)
        XCTAssertTrue(calls.urls.isEmpty)
    }

    func testRepeatedManualDockerInstallationKeepsOneRestartOffer() {
        let calls = ManualDockerRestartRecorder()
        let store = makeStore(calls: calls)

        store.queueDockerRestart(token: "docker", bundleURL: bundleURL)
        store.queueDockerRestart(token: "docker-desktop", bundleURL: bundleURL)

        XCTAssertEqual(store.restartCandidates.count, 1)
        XCTAssertEqual(Array(store.restartDockerBundleURLs.values), [bundleURL])
        XCTAssertTrue(calls.urls.isEmpty)
    }

    private func makeStore(calls: ManualDockerRestartRecorder) -> ScanStore {
        let operations = OperationCoordinator()
        var dependencies = ScanStoreDependencies(
            operations: operations, upgrades: UpgradeCoordinator(operations: operations),
            caskAppPathResolver: CaskAppPathResolver(), bundleExists: { _ in true },
            manualScan: { _, _ in ([], 0) }, reportWindowScan: { _, _, _ in },
            recordUpdateRun: { _ in }, settleAppManagementPermission: { _ in }, undoableUpdates: { [] }
        )
        dependencies.restartDocker = { url in
            calls.record(url)
            return .ready
        }
        return ScanStore(resultStore: ScanResultStore(io: ScanStoreRuntimeSnapshotIO()), dependencies: dependencies)
    }
}

private final class ManualDockerRestartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []
    var urls: [URL] { lock.withLock { recordedURLs } }
    func record(_ url: URL) { lock.withLock { recordedURLs.append(url) } }
}
