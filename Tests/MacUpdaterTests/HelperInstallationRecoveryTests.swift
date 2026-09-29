import Foundation
import Testing
import WegaHelperKit
@testable import MacUpdaterCore

@Suite("An XPC timeout does not release an installation")
struct HelperInstallationRecoveryTests {
    @Test func aRequestLostBeforeDeliveryCanBeReleasedWithoutStartingALateInstaller() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let registry = try PackageInstallationRegistry(fileURL: fixture.root.appendingPathComponent("helper.json"), bootID: "test-boot")
        let installer = HelperPackageInstallation(
            store: fixture.store, handshake: {},
            begin: { _, _ in throw InstallationChannel.Disconnected() },
            status: { id in try registry.status(id) }
        )
        await #expect(throws: HelperPackageInstallation.Failure.self) {
            try await installer.install(at: "/tmp/Wega.pkg", version: "3.0")
        }
        let pending = try #require(try fixture.store.load())
        await #expect(throws: HelperPackageInstallation.Failure.self) { try await installer.reconcile() }
        #expect(!fixture.store.hasPending)
        #expect(try !registry.begin(pending.operationID))
    }

    @Test func anotherOperationsTerminalReplyCannotReleaseTheReceipt() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let installer = HelperPackageInstallation(
            store: fixture.store, handshake: {},
            begin: { _, _ in PackageInstallationStatus(operationID: UUID(), phase: .succeeded) },
            status: { _ in PackageInstallationStatus(operationID: UUID(), phase: .succeeded) }
        )
        await #expect(throws: HelperPackageInstallation.Failure.self) {
            try await installer.install(at: "/tmp/Wega.pkg", version: "3.0")
        }
        await #expect(throws: HelperPackageInstallation.Failure.self) { try await installer.reconcile() }
        #expect(fixture.store.hasPending)
    }

    @Test func lateConfirmedRepliesCannotClearANewerReceipt() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let old = PendingHelperInstallation(operationID: UUID(), version: "3.0")
        let newer = PendingHelperInstallation(operationID: UUID(), version: "4.0")
        try fixture.store.reserve(old)
        try fixture.store.clear(matching: old.operationID)
        try fixture.store.clear(matching: old.operationID)
        try fixture.store.reserve(newer)
        #expect(throws: PendingHelperInstallationStore.Failure.self) { try fixture.store.clear(matching: old.operationID) }
        #expect(try fixture.store.load() == newer)
    }

    @Test func anUnreadableReceiptCannotUnlockTheGate() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("broken receipt".utf8).write(to: fixture.root.appendingPathComponent("pending.json"))
        let gate = OperationCoordinator(pendingInstallationStore: fixture.store)
        #expect(fixture.store.hasPending)
        await #expect(throws: OperationCoordinator.LeaseError.self) {
            try await gate.withWrite(label: "must not start") { true }
        }
        await #expect(throws: (any Error).self) { try await fixture.installer(InstallationChannel()).reconcile() }
        #expect(fixture.store.hasPending)
    }

    @Test func aBlockedBackgroundScanDoesNotClaimAnEmptyCompleteResult() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.reserve(PendingHelperInstallation(operationID: UUID(), version: "3.0"))
        let gate = OperationCoordinator(pendingInstallationStore: fixture.store)
        let checker = MenuBarUpdateChecker(
            brewService: SuspendedBrew(), masService: SuspendedMas(), npmService: SuspendedNpm(),
            scanner: SuspendedManual(), operations: gate
        )
        let result = await checker.availableUpdateCount()
        #expect(result.total == 0)
        #expect(result.failedChecks == 1)
    }

    @Test func lostReplyKeepsTheGateBlockedAcrossAClientRestart() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let channel = InstallationChannel(dropStartReply: true)
        let installer = fixture.installer(channel)
        await #expect(throws: HelperPackageInstallation.Failure.self) {
            try await installer.install(at: "/tmp/Wega.pkg", version: "3.0", timeout: .zero)
        }
        let pending = try #require(try fixture.store.load())
        #expect(pending.version == "3.0")
        let restartedGate = OperationCoordinator(pendingInstallationStore: fixture.store)
        await #expect(throws: OperationCoordinator.LeaseError.self) {
            try await restartedGate.withWrite(label: "another installation") { true }
        }
        #expect(await restartedGate.snapshot().isWriting)
        await channel.setPhase(.succeeded)
        #expect(try await installer.reconcile() == pending)
        #expect(!fixture.store.hasPending)
        #expect(try await restartedGate.withWrite(label: "now safe") { true })
        #expect(await channel.starts == 1)
    }

    @Test func aRunningOrUnreachableHelperCannotBeReportedAsFinished() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let channel = InstallationChannel()
        let installer = fixture.installer(channel)
        await #expect(throws: HelperPackageInstallation.Failure.self) {
            try await installer.install(at: "/tmp/Wega.pkg", version: "3.0", timeout: .zero)
        }
        await #expect(throws: HelperPackageInstallation.Failure.self) { try await installer.reconcile() }
        #expect(fixture.store.hasPending)
        await channel.setDropStatus(true)
        await #expect(throws: HelperPackageInstallation.Failure.self) { try await installer.reconcile() }
        #expect(fixture.store.hasPending)
        #expect(await channel.starts == 1)
    }

    @Test func handshakeFailureDoesNotReserveAnOperationAndTerminalRejectionReleasesIt() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let channel = InstallationChannel()
        let rejectedHandshake = HelperPackageInstallation(
            store: fixture.store, handshake: { throw InstallationChannel.Disconnected() },
            begin: { id, path in try await channel.begin(id, path: path) },
            status: { id in try await channel.status(id) }
        )
        await #expect(throws: InstallationChannel.Disconnected.self) {
            try await rejectedHandshake.install(at: "/tmp/Wega.pkg", version: "3.0")
        }
        #expect(!fixture.store.hasPending)
        #expect(await channel.starts == 0)
        await channel.setPhase(.failed)
        await #expect(throws: HelperPackageInstallation.Failure.self) {
            try await fixture.installer(channel).install(at: "/tmp/Wega.pkg", version: "3.0")
        }
        #expect(!fixture.store.hasPending)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var store: PendingHelperInstallationStore { PendingHelperInstallationStore(fileURL: root.appendingPathComponent("pending.json")) }
        func installer(_ channel: InstallationChannel) -> HelperPackageInstallation {
            HelperPackageInstallation(
                store: store, handshake: {}, begin: { id, path in try await channel.begin(id, path: path) },
                status: { id in try await channel.status(id) }
            )
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private struct SuspendedBrew: BrewOutdatedProviding {
    func outdatedGreedy() async throws -> BrewOutdated { BrewOutdated(formulae: [], casks: []) }
}
private struct SuspendedMas: MasOutdatedProviding {
    func outdated() async throws -> [MasOutdatedApp] { [] }
}
private struct SuspendedNpm: NpmOutdatedProviding {
    func outdated() async throws -> [NpmGlobalOutdated] { [] }
}
private struct SuspendedManual: ManualScanning {
    func scan(brewOutdatedCasks: Set<String>) async -> (apps: [ManualOutdatedApp], failedChecks: Int) { ([], 0) }
}

private actor InstallationChannel {
    struct Disconnected: Error {}
    private var phase = PackageInstallationStatus.Phase.running
    private var dropStatus = false
    private let dropStartReply: Bool
    private(set) var starts = 0

    init(dropStartReply: Bool = false) { self.dropStartReply = dropStartReply }
    func setPhase(_ phase: PackageInstallationStatus.Phase) { self.phase = phase }
    func setDropStatus(_ value: Bool) { dropStatus = value }
    func begin(_ id: UUID, path: String) throws -> PackageInstallationStatus {
        starts += 1
        if dropStartReply { throw Disconnected() }
        return PackageInstallationStatus(operationID: id, phase: phase)
    }
    func status(_ id: UUID) throws -> PackageInstallationStatus {
        if dropStatus { throw Disconnected() }
        return PackageInstallationStatus(operationID: id, phase: phase)
    }
}
