import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

private enum RecoveryRuntimeError: Error {
    case expected
}

private final class RecoveryRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var existingPathsStorage: Set<String> = []
    private var removedStorage: [URL] = []
    private var clonedStorage: [(URL, URL)] = []
    private var rollbackTokensStorage: [String] = []
    private var announcedStorage: [UpdateOperationRecovery.Report] = []

    var existingPaths: Set<String> {
        get { lock.withLock { existingPathsStorage } }
        set { lock.withLock { existingPathsStorage = newValue } }
    }

    var removed: [URL] { lock.withLock { removedStorage } }
    var cloned: [(URL, URL)] { lock.withLock { clonedStorage } }
    var rollbackTokens: [String] { lock.withLock { rollbackTokensStorage } }
    var announced: [UpdateOperationRecovery.Report] { lock.withLock { announcedStorage } }

    func recordRemoval(_ url: URL) {
        lock.withLock { removedStorage.append(url) }
    }

    func recordClone(_ source: URL, _ destination: URL) {
        lock.withLock { clonedStorage.append((source, destination)) }
    }

    func recordRollback(_ token: String) {
        lock.withLock { rollbackTokensStorage.append(token) }
    }

    func recordAnnouncement(_ report: UpdateOperationRecovery.Report) {
        lock.withLock { announcedStorage.append(report) }
    }
}

@Suite("Update operation recovery runtime coverage")
@MainActor
struct UpdateOperationRecoveryRuntimeTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-runtime-\(UUID().uuidString)", isDirectory: true)
    }

    private func dependencies(
        recorder: RecoveryRuntimeRecorder,
        appVersion: @escaping @Sendable (URL) -> String? = { _ in "1.0" },
        verify: (@MainActor @Sendable (
            [String], [String: URL], [String: URL], UpdateOperationSession
        ) async -> [String: CaskValidationVerdict])? = nil,
        clone: (@Sendable (URL, URL) throws -> Void)? = nil,
        legacyDirectory: URL? = nil
    ) -> UpdateOperationRecovery.Dependencies {
        UpdateOperationRecovery.Dependencies(
            fileExists: { recorder.existingPaths.contains($0) },
            appVersion: appVersion,
            verify: verify ?? { _, _, _, _ in [:] },
            clone: clone ?? { recorder.recordClone($0, $1) },
            recordRollback: { recorder.recordRollback($0) },
            removeItem: { recorder.recordRemoval($0) },
            legacyDirectory: {
                legacyDirectory ?? URL(fileURLWithPath: "/tmp/no-legacy-runtime-test")
            },
            announce: { recorder.recordAnnouncement($0) }
        )
    }

    private func session(
        store: UpdateOperationStore,
        token: String,
        appPath: String,
        phase: UpdateOperationPhase
    ) -> UpdateOperationSession {
        let session = store.begin(trigger: .background)
        session.recordPlanned(
            tokens: [token],
            appPaths: [token: URL(fileURLWithPath: appPath)]
        )
        if phase == .snapshotted || phase == .installing {
            session.recordSnapshotted(token: token, snapshotName: "\(token).app")
        }
        if phase == .installing {
            session.recordInstalling()
        }
        return session
    }

    private func write(_ operation: UpdateOperation, to store: UpdateOperationStore) throws {
        let directory = store.operationDirectory(id: operation.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(operation).write(to: directory.appendingPathComponent("operation.json"))
    }

    @Test func settlesPlannedSnapshottedVerifiedAndUntouchedItemsInOnePass() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        _ = session(store: store, token: "planned", appPath: "/apps/planned.app", phase: .planned)
        _ = session(store: store, token: "snapshotted", appPath: "/apps/snapshotted.app", phase: .snapshotted)
        let untouched = UpdateOperationItem(
            token: "untouched",
            appPath: "/apps/untouched.app",
            bundleIdentifier: nil,
            preUpgradeVersion: "1.0",
            phase: .installing
        )
        let verified = UpdateOperationItem(
            token: "verified",
            appPath: "/apps/verified.app",
            bundleIdentifier: nil,
            preUpgradeVersion: "1.0",
            phase: .verified
        )
        try write(
            UpdateOperation(
                id: UUID(),
                startedAt: Date(),
                trigger: .background,
                items: [verified]
            ),
            to: store
        )
        try write(
            UpdateOperation(
                id: UUID(),
                startedAt: Date(),
                trigger: .background,
                items: [untouched]
            ),
            to: store
        )

        let recorder = RecoveryRuntimeRecorder()
        recorder.existingPaths = ["/apps/untouched.app"]
        let recovery = UpdateOperationRecovery(
            store: store,
            dependencies: dependencies(recorder: recorder)
        )

        let report = await recovery.recoverInterruptedOperations()

        #expect(Set(report.abortedTokens) == ["planned", "snapshotted", "untouched"])
        #expect(report.committedTokens == ["verified"])
        #expect(report.rolledBackTokens.isEmpty)
        #expect(report.unrecoverableTokens.isEmpty)
        #expect(recorder.removed.contains { $0.lastPathComponent == "snapshotted.app" })
        #expect(recorder.announced == [report])
    }

    @Test func mutatedInstallsAreClassifiedFromInjectedCanaryVerdictsAndRetriedOnlyOnce() async {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        for token in ["healthy", "rolled", "failed"] {
            _ = session(
                store: store,
                token: token,
                appPath: "/apps/\(token).app",
                phase: .installing
            )
        }

        let recorder = RecoveryRuntimeRecorder()
        recorder.existingPaths = Set(["healthy", "rolled", "failed"].map { "/apps/\($0).app" })
        let recovery = UpdateOperationRecovery(
            store: store,
            dependencies: dependencies(
                recorder: recorder,
                appVersion: { _ in "2.0" },
                verify: { tokens, _, _, operation in
                    let token = tokens[0]
                    let verdict: CaskValidationVerdict
                    switch token {
                    case "healthy": verdict = .healthy
                    case "rolled": verdict = .rolledBack
                    default: verdict = .rollbackFailed
                    }
                    operation.recordVerdict(token: token, verdict: verdict)
                    return [token: verdict]
                }
            )
        )

        let first = await recovery.recoverInterruptedOperations()
        let second = await recovery.recoverInterruptedOperations()

        #expect(first.committedTokens == ["healthy"])
        #expect(first.rolledBackTokens == ["rolled"])
        #expect(first.unrecoverableTokens == ["failed"])
        #expect(second.isEmpty)
        #expect(store.operations().first { $0.items.first?.token == "failed" }?.items.first?.recoveryAttempts == 1)
    }

    @Test func missingAppsCoverSuccessfulAbsentAndFailedSnapshotRestoration() async {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let restored = session(
            store: store,
            token: "restored",
            appPath: "/apps/restored.app",
            phase: .installing
        )
        let broken = session(
            store: store,
            token: "broken",
            appPath: "/apps/broken.app",
            phase: .installing
        )
        _ = session(
            store: store,
            token: "absent",
            appPath: "/apps/absent.app",
            phase: .installing
        )

        let recorder = RecoveryRuntimeRecorder()
        recorder.existingPaths = [
            store.snapshotURL(operationID: restored.operation.id, name: "restored.app").path,
            store.snapshotURL(operationID: broken.operation.id, name: "broken.app").path,
        ]
        let recovery = UpdateOperationRecovery(
            store: store,
            dependencies: dependencies(
                recorder: recorder,
                clone: { source, destination in
                    if source.lastPathComponent == "broken.app" {
                        throw RecoveryRuntimeError.expected
                    }
                    recorder.recordClone(source, destination)
                }
            )
        )

        let report = await recovery.recoverInterruptedOperations()

        #expect(report.rolledBackTokens == ["restored"])
        #expect(Set(report.unrecoverableTokens) == ["absent", "broken"])
        #expect(recorder.rollbackTokens == ["restored"])
        #expect(recorder.cloned.first?.1.path == "/apps/restored.app")
    }

    @Test func sweepsLegacyDirectoryEvenWhenThereIsNothingToRecover() async {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = URL(fileURLWithPath: "/tmp/recovery-runtime-legacy-\(UUID().uuidString)")
        let recorder = RecoveryRuntimeRecorder()
        recorder.existingPaths = [legacy.path]
        let recovery = UpdateOperationRecovery(
            store: UpdateOperationStore(rootDirectory: root),
            dependencies: dependencies(
                recorder: recorder,
                legacyDirectory: legacy
            )
        )

        let report = await recovery.recoverInterruptedOperations()

        #expect(report.isEmpty)
        #expect(recorder.removed == [legacy])
        #expect(recorder.announced.isEmpty)
    }
}
