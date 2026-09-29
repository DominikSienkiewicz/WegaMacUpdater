import Foundation
import Testing
@testable import MacUpdaterCore
import WegaHelperKit

@Suite("Tracked helper verifies the installed version")
struct HelperExpectedVersionTests {
    private struct WrongInstalledVersion: Error {}

    @Test func sendsTargetVersionToInstallerBeforeRecordingSuccess() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PendingHelperInstallationStore(fileURL: file)
        let installer = HelperPackageInstallation(store: store, handshake: {}, begin: { id, _, version in
            #expect(version == "3.0")
            return .init(operationID: id, phase: .succeeded)
        }, status: { id in .init(operationID: id, phase: .unknown) }, verifyInstalled: { version in
            #expect(version == "3.0")
            throw WrongInstalledVersion()
        })
        await #expect(throws: WrongInstalledVersion.self) {
            try await installer.install(at: "/tmp/Wega.pkg", version: "3.0")
        }
        #expect(!store.hasPending)
    }

    @Test func recoveredSuccessAlsoRequiresExpectedVersionOnDisk() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PendingHelperInstallationStore(fileURL: file)
        try store.reserve(.init(operationID: UUID(), version: "3.0"))
        let installer = HelperPackageInstallation(store: store, handshake: {}, begin: { id, _, _ in
            Issue.record("Recovery must never start installation")
            return .init(operationID: id, phase: .unknown)
        }, status: { id in .init(operationID: id, phase: .succeeded) }, verifyInstalled: { version in
            #expect(version == "3.0")
            throw WrongInstalledVersion()
        })
        await #expect(throws: WrongInstalledVersion.self) { try await installer.reconcile() }
        #expect(!store.hasPending)
    }
}
