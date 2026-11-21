import Foundation
import MacUpdaterCore
import XCTest
@testable import WegaMacUpdater

@MainActor
final class DockerDesktopRestartUITests: XCTestCase {
    private let info = RestartInfo(processName: "Docker Desktop", appName: "Docker")
    private let bundleURL = URL(fileURLWithPath: "/TestApplications/Docker.app")

    func testFailedReadinessKeepsRetryCandidateAndReportsEngineFailure() async {
        let calls = DockerRestartCallRecorder()
        let store = makeStore(result: .readinessTimedOut("engine unavailable"), calls: calls)
        prepare(store)

        await store.restartApp(info)

        XCTAssertEqual(calls.urls, [bundleURL])
        XCTAssertEqual(store.restartCandidates, [info])
        XCTAssertEqual(store.restartDockerBundleURLs[info.processName], bundleURL)
        XCTAssertEqual(store.banner?.variant, .danger)
        XCTAssertEqual(store.banner?.action, .openLogs, "an unconfirmed engine says where to look next")
        XCTAssertTrue(store.banner?.message.contains("engine unavailable") == true)
        XCTAssertNil(store.restartBusy)
    }

    func testReadyEngineRemovesCandidateAndReportsReadiness() async {
        let calls = DockerRestartCallRecorder()
        let store = makeStore(result: .ready, calls: calls)
        prepare(store)

        await store.restartApp(info)

        XCTAssertEqual(calls.urls, [bundleURL])
        XCTAssertTrue(store.restartCandidates.isEmpty)
        XCTAssertNil(store.restartDockerBundleURLs[info.processName])
        XCTAssertNil(store.restartDiagnosticOperationIDs[info.processName])
        XCTAssertEqual(store.banner?.variant, .success)
        XCTAssertEqual(store.banner?.title, tr("Silnik Docker gotowy"))
        XCTAssertNil(store.banner?.action)
        XCTAssertNil(store.restartBusy)
    }

    func testDockerWithoutResolvedBundleNeverFallsBackToGenericRestart() async {
        let calls = DockerRestartCallRecorder()
        let store = makeStore(result: .ready, calls: calls)
        store.restartCandidates = [info]

        await store.restartApp(info)

        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertEqual(store.restartCandidates, [info])
        XCTAssertEqual(store.banner?.variant, .danger)
        XCTAssertEqual(store.banner?.action, .openLogs)
        XCTAssertNil(store.restartBusy)
    }

    func testInstallationSuccessDoesNotClaimOrTriggerEngineReadiness() {
        let calls = DockerRestartCallRecorder()
        let store = makeStore(result: .ready, calls: calls)
        let item = OutdatedItem(key: "c:docker-desktop", name: "docker-desktop", from: "4.1", to: "4.2", kind: .cask)
        var run = UpdateRunOutcome()
        run.record([item], outcome: BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: []))

        store.report(run: run, planned: [item])

        // C2 stage 4 — the summary's Docker row says it, instead of the success banner.
        XCTAssertEqual(store.runReport?.entries.first?.note(undo: nil),
                       tr("Pakiety zainstalowane. Gotowość silnika Docker nie była sprawdzana."))
        XCTAssertTrue(calls.urls.isEmpty)
    }

    func testUnrelatedInstallationKeepsTheOrdinaryNote() {
        let store = makeStore(result: .ready, calls: DockerRestartCallRecorder())
        let item = OutdatedItem(key: "c:example", name: "example", from: "1", to: "2", kind: .cask)
        var run = UpdateRunOutcome()
        run.record([item], outcome: BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: []))

        store.report(run: run, planned: [item])

        XCTAssertEqual(store.runReport?.entries.first?.note(undo: nil), tr("bez cofnięcia"))
        XCTAssertNil(store.banner)
    }

    private func prepare(_ store: ScanStore) {
        store.restartCandidates = [info]
        store.restartDockerBundleURLs[info.processName] = bundleURL
        store.restartDiagnosticOperationIDs[info.processName] = UUID()
    }

    private func makeStore(result: DockerDesktopRestartResult, calls: DockerRestartCallRecorder) -> ScanStore {
        let operations = OperationCoordinator()
        var dependencies = ScanStoreDependencies(
            operations: operations, upgrades: UpgradeCoordinator(operations: operations),
            caskAppPathResolver: CaskAppPathResolver(), bundleExists: { _ in true },
            manualScan: { _, _ in ([], 0) }, reportWindowScan: { _, _, _ in },
            recordUpdateRun: { _ in }, settleAppManagementPermission: { _ in }, undoableUpdates: { [] }
        )
        dependencies.restartDocker = { url in
            calls.record(url)
            return result
        }
        return ScanStore(resultStore: ScanResultStore(io: ScanStoreRuntimeSnapshotIO()), dependencies: dependencies)
    }
}

private final class DockerRestartCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []
    var urls: [URL] { lock.withLock { recordedURLs } }
    func record(_ url: URL) { lock.withLock { recordedURLs.append(url) } }
}
