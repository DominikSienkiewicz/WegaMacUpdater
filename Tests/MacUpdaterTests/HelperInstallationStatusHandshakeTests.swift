import Foundation
import Testing
import WegaHelperKit
@testable import MacUpdaterCore

/// RC1 of the Z14 design review: since protocol 9 an older helper is sent no acting verb, but it may
/// still have run the installation the app is waiting on. Settling it asks only for the status, whose
/// minimum stays at 6, so a pending record never gets stuck behind a handshake for another verb.
@Suite("Settling an installation handshakes for its status")
struct HelperInstallationStatusHandshakeTests {
    @Test func installHandshakesForTheInstallationAndReconcileForTheStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wega-status-handshake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingHelperInstallationStore(fileURL: root.appendingPathComponent("pending.json"))
        let calls = Calls()
        let installer = HelperPackageInstallation(
            store: store,
            handshake: { await calls.record("installation") },
            statusHandshake: { await calls.record("status") },
            begin: { id, _, _ in PackageInstallationStatus(operationID: id, phase: .succeeded) },
            status: { id in PackageInstallationStatus(operationID: id, phase: .succeeded) },
            verifyInstalled: { _ in }
        )

        try await installer.install(at: "/tmp/Wega.pkg", version: "3.0")
        #expect(await calls.list == ["installation"])

        try store.reserve(PendingHelperInstallation(operationID: UUID(), version: "3.0"))
        _ = try await installer.reconcile()
        #expect(await calls.list == ["installation", "status"])
    }

    private actor Calls {
        private(set) var list: [String] = []
        func record(_ name: String) { list.append(name) }
    }
}
