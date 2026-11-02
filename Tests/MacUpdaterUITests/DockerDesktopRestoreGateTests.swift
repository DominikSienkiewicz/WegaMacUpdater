import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

private actor DockerRestoreStopRecorder {
    private(set) var paths: [URL] = []
    private var results: [DockerDesktopStopResult]

    init(_ results: [DockerDesktopStopResult] = [.timedOut]) { self.results = results }

    func stop(_ path: URL) -> DockerDesktopStopResult {
        paths.append(path)
        return results.isEmpty ? .timedOut : results.removeFirst()
    }
}

@Suite("Docker Desktop restore gates", .serialized)
@MainActor
struct DockerDesktopRestoreGateTests {
    private let appURL = URL(fileURLWithPath: "/TestApplications/Docker.app")
    private let snapshotURL = URL(fileURLWithPath: "/TestSnapshots/Docker.app")

    @Test(arguments: [nil, "docker-desktop"] as [String?])
    func stoppedDesktopIsRequiredBeforeRestoringEvenWithoutToken(token: String?) async {
        let recorder = DockerRestoreStopRecorder()
        var dependencies = CaskRollbackGuard.Dependencies.live
        dependencies.bundleIdentifier = { _ in "com.docker.docker" }
        dependencies.stopDocker = { await recorder.stop($0) }
        dependencies.clone = { _, _ in Issue.record("Must not clone before shutdown confirmation") }
        dependencies.restore = { _, _ in Issue.record("Must not replace before shutdown confirmation") }
        dependencies.removeItem = { _ in Issue.record("Must retain snapshot on shutdown failure") }
        dependencies.helperIsEnabled = { true }
        dependencies.helperReplace = { _, _ in Issue.record("Root helper cannot bypass shutdown gate") }

        let restored = await CaskRollbackGuard.restoreSnapshot(
            snapshotURL, to: appURL, preservingSnapshot: true, token: token, dependencies: dependencies
        )

        #expect(!restored)
        #expect(await recorder.paths == [appURL])
    }

    @Test func helperFallbackRechecksShutdownAfterLocalRestoreFailure() async {
        let recorder = DockerRestoreStopRecorder([.stopped, .timedOut])
        var dependencies = CaskRollbackGuard.Dependencies.live
        dependencies.stopDocker = { await recorder.stop($0) }
        dependencies.restore = { _, _ in throw RestoreError.expected }
        dependencies.helperIsEnabled = { true }
        dependencies.helperReplace = { _, _ in Issue.record("Must not invoke helper after Desktop restarted") }

        let restored = await CaskRollbackGuard.restoreSnapshot(snapshotURL, to: appURL, token: "docker", dependencies: dependencies)

        #expect(!restored)
        #expect(await recorder.paths == [appURL, appURL])
    }

    @Test func snapshotPreservationCannotLeaveAnUncheckedGapBeforeReplacement() async {
        let recorder = DockerRestoreStopRecorder([.stopped, .timedOut])
        var dependencies = CaskRollbackGuard.Dependencies.live
        dependencies.stopDocker = { await recorder.stop($0) }
        dependencies.clone = { _, _ in }
        dependencies.restore = { _, _ in Issue.record("Docker may restart while the retained snapshot is cloned") }
        dependencies.removeItem = { _ in }

        let restored = await CaskRollbackGuard.restoreSnapshot(
            snapshotURL, to: appURL, preservingSnapshot: true, token: "docker", dependencies: dependencies
        )

        #expect(!restored)
        #expect(await recorder.paths == [appURL, appURL])
    }

    @Test func missingAppRecoveryPreservesSnapshotWhenShutdownIsUnknown() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docker-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let operation = store.begin(trigger: .manual)
        operation.recordPlanned(tokens: ["docker-desktop"], appPaths: ["docker-desktop": appURL])
        operation.recordSnapshotted(token: "docker-desktop", snapshotName: "Docker.app")
        operation.recordInstalling()
        let recorder = DockerRestoreStopRecorder()
        var dependencies = UpdateOperationRecovery.Dependencies.live
        let missingPath = appURL.path
        dependencies.fileExists = { $0 != missingPath }
        dependencies.appVersion = { _ in nil }
        dependencies.stopDocker = { await recorder.stop($0) }
        dependencies.clone = { _, _ in Issue.record("Missing-app recovery must not clone after shutdown failure") }
        dependencies.recordRollback = { _ in Issue.record("No rollback completed") }
        dependencies.removeItem = { _ in }
        dependencies.legacyDirectory = { root.appendingPathComponent("legacy") }
        dependencies.announce = { _ in }

        let report = await UpdateOperationRecovery(store: store, dependencies: dependencies).recoverInterruptedOperations()

        #expect(report.rolledBackTokens.isEmpty)
        #expect(report.unrecoverableTokens == ["docker-desktop"])
        #expect(await recorder.paths == [appURL])
    }

    private enum RestoreError: Error { case expected }
}
