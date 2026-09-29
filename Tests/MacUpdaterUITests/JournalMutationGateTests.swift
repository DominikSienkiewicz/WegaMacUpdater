import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Journal failures stop mutations")
@MainActor
struct JournalMutationGateTests {
    @Test(arguments: [UpdateOperationPhase.planned, .snapshotted, .installing])
    func backgroundWriteFailureStopsBeforeBrewAndVerification(_ failingPhase: UpdateOperationPhase) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root, writeJournal: { data, url in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if try decoder.decode(UpdateOperation.self, from: data).items.contains(where: { $0.phase == failingPhase }) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        let probe = JournalGateProbe()
        let app = root.appendingPathComponent("Example.app")
        let updater = BackgroundUpdater(dependencies: .init(
            optedInTokens: { ["example"] }, allowsRound: { true },
            loadPreflight: { _ in BackgroundUpdatePreflight(
                profiles: [.init(token: "example", artifacts: [.init(kind: .app, names: ["Example.app"])])],
                downloads: [.init(token: "example", url: "https://example.invalid/app.zip", sha256: "abc")],
                appPaths: ["example": app]
            ) },
            runningTokens: { _ in [] }, probeDownloadSizes: { _, _ in ["example": .known(bytes: 1)] },
            performWrite: { await $0() }, acquireMutex: { true }, releaseMutex: { probe.released = true },
            policies: { [:] }, resourceDecision: { _, _, _ in .allow }, publisherVetoes: { _, _ in [:] },
            beginOperation: { store.begin(trigger: .background) },
            snapshot: { _, _, operation in
                operation.recordSnapshotted(token: "example", snapshotName: "example.app")
                return ["example": operation.snapshotsDirectory.appendingPathComponent("example.app")]
            },
            removeOperation: { store.removeOperation(id: $0) },
            runBrew: { _ in probe.brewStarted = true; return .init(exitCode: 0, failedTokens: [], errorLines: []) },
            recordAppManagementDenial: {}, clearAppManagementDenial: {},
            verify: { _, _, _, _ in probe.verified = true; return [:] },
            outdatedGreedy: { .init(formulae: [], casks: []) }, notify: { _ in }
        ))
        #expect(await updater.runIfEligible(candidates: ["example"], policies: [:]).isEmpty)
        #expect(!probe.brewStarted)
        #expect(!probe.verified)
        #expect(probe.released)
    }

    @Test func foregroundLaneRefusesAnUnpersistedInstallingPhase() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root, writeJournal: { data, url in
            if String(decoding: data, as: UTF8.self).contains("\"installing\"") { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let session = store.begin(trigger: .manual)
        let app = root.appendingPathComponent("Example.app")
        session.recordPlanned(tokens: ["example"], appPaths: ["example": app])
        session.recordSnapshotted(token: "example", snapshotName: "example.app")
        let scan = ScanStore()
        let results = await scan.runCaskLane(
            items: [.init(key: "c:example", name: "example", from: "1.0", to: "2.0", kind: .cask)],
            preparation: ForegroundCaskPreparation(
                appPaths: ["example": app], snapshots: ["example": session.snapshotsDirectory.appendingPathComponent("example.app")],
                trustedCaskNames: ["example"], publisherVetoes: [:], operation: session
            )
        )
        #expect(results.isEmpty)
        #expect(scan.brewLog.contains { $0.contains("dziennika odzyskiwania") || $0.contains("recovery journal") })
    }

    @Test func legacySnapshottedJournalCannotAuthorizeDeletingTheOnlyCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateOperationStore(rootDirectory: root)
        let session = store.begin(trigger: .manual)
        session.recordPlanned(tokens: ["example"], appPaths: ["example": root.appendingPathComponent("Example.app")])
        session.recordSnapshotted(token: "example", snapshotName: "example.app")
        let journal = store.operationDirectory(id: session.operation.id).appendingPathComponent("operation.json")
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        legacy.removeValue(forKey: "persistenceVersion")
        try JSONSerialization.data(withJSONObject: legacy).write(to: journal)
        let snapshot = session.snapshotsDirectory.appendingPathComponent("example.app")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let recovery = UpdateOperationRecovery(store: store, dependencies: .init(
            fileExists: { FileManager.default.fileExists(atPath: $0) }, appVersion: { _ in "1.0" },
            verify: { _, _, _, _ in [:] }, clone: { _, _ in Issue.record("Must not restore an ambiguous journal automatically") },
            recordRollback: { _ in }, removeItem: { try FileManager.default.removeItem(at: $0) },
            legacyDirectory: { root.appendingPathComponent("absent") }, announce: { _ in }
        ))
        let report = await recovery.recoverInterruptedOperations()
        #expect(report.unrecoverableTokens == ["example"])
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        #expect(store.operations().first?.items.first?.phase == .snapshotted)
    }
}

@MainActor
private final class JournalGateProbe {
    var brewStarted = false
    var verified = false
    var released = false
}
