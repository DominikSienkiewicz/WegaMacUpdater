import Foundation
import Testing
import WegaHelperKit
@testable import MacUpdaterCore

@Suite("Helper operation identity across connection loss")
struct TrackedHelperIntegrationTests {
    @Test func cancelledObservationReconnectsToTheSameDurableOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try PackageInstallationRegistry(fileURL: root.appendingPathComponent("helper/state.json"), bootID: "boot")
        let file = root.appendingPathComponent("client/pending.json")
        let store = PendingHelperInstallationStore(fileURL: file)
        let firstClient = HelperPackageInstallation(
            store: store, handshake: {},
            begin: { id, _ in
                #expect(try helper.begin(id))
                throw CancellationError()
            },
            status: { try helper.status($0) }
        )
        await #expect(throws: HelperPackageInstallation.Failure.self) {
            try await firstClient.install(at: "/unused/Wega.pkg", version: "3.0")
        }
        let pending = try #require(try store.load())
        #expect(try helper.status(pending.operationID).phase == .running)
        let restartedStore = PendingHelperInstallationStore(fileURL: file)
        let gate = OperationCoordinator(pendingInstallationStore: restartedStore)
        #expect(await gate.snapshot().isWriting)
        let secondClient = HelperPackageInstallation(
            store: restartedStore, handshake: {},
            begin: { _, _ in Issue.record("Reconciliation must never start a new operation"); throw CancellationError() },
            status: { try helper.status($0) }
        )
        await #expect(throws: HelperPackageInstallation.Failure.self) { try await secondClient.reconcile() }
        #expect(restartedStore.hasPending)
        #expect(try !helper.begin(pending.operationID))
        try helper.finish(pending.operationID, succeeded: true, message: nil)
        #expect(try await secondClient.reconcile() == pending)
        #expect(!restartedStore.hasPending)
        #expect(await gate.snapshot().isIdle)
    }

    @Test func cancellationBeforeDispatchCreatesNoReceipt() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingHelperInstallationStore(fileURL: root.appendingPathComponent("pending.json"))
        let client = HelperPackageInstallation(
            store: store,
            handshake: { withUnsafeCurrentTask { $0?.cancel() } },
            begin: { _, _ in Issue.record("A cancelled request must not reach the helper"); throw CancellationError() },
            status: { _ in throw CancellationError() }
        )
        let task = Task {
            await #expect(throws: CancellationError.self) { try await client.install(at: "/unused/Wega.pkg", version: "3.0") }
        }
        await task.value
        #expect(!store.hasPending)
    }
}
