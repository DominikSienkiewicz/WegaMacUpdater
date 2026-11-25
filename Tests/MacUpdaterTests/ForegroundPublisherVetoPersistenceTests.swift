import Foundation
import Testing

/// SEC-02 follow-up: a publisher mismatch is already a critical result when snapshotting
/// a different cask fails. The later preparation failure must not discard that signal.
@Suite("Foreground publisher veto persistence")
struct ForegroundPublisherVetoPersistenceTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func snapshotFailureStillReportsPublisherVetoBeforeReturning() throws {
        let rollback = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/ScanStore+Rollback.swift"),
            encoding: .utf8
        )
        let updating = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/ScanStore+Updating.swift"),
            encoding: .utf8
        )
        let preparationStart = try #require(rollback.range(of: "func prepareForegroundCasks("))
        let preparationEnd = try #require(rollback.range(
            of: "func foregroundResourceDecision(",
            range: preparationStart.upperBound..<rollback.endIndex
        ))
        let preparation = rollback[preparationStart.lowerBound..<preparationEnd.lowerBound]
        let veto = try #require(preparation.range(
            of: "let publisherVetoes = CaskRollbackGuard.publisherVetoes("))
        let snapshot = try #require(preparation.range(of: "let snapshots = snapshotCasks("))
        let missingSnapshot = try #require(preparation.range(of: "guard missing.isEmpty else {"))
        let ready = try #require(preparation.range(of: "return .ready(ForegroundCaskPreparation("))
        let blocked = try #require(preparation.range(
            of: "return .blocked(publisherVetoes: publisherVetoes)",
            range: missingSnapshot.upperBound..<ready.lowerBound
        ))
        #expect(veto.lowerBound < snapshot.lowerBound)
        #expect(snapshot.lowerBound < missingSnapshot.lowerBound)
        #expect(snapshot.lowerBound < blocked.lowerBound)

        let updateStart = try #require(updating.range(of: "private func runUpdateCoordinated("))
        let updateEnd = try #require(updating.range(
            of: "func report(run: UpdateRunOutcome, planned:",
            range: updateStart.upperBound..<updating.endIndex
        ))
        let update = updating[updateStart.lowerBound..<updateEnd.lowerBound]
        let blockedCase = try #require(update.range(of: "case .blocked(let publisherVetoes):"))
        let record = try #require(update.range(of: "blockedRun.recordPublisherVetoes("))
        let report = try #require(update.range(of: "report(run: blockedRun, planned: plannedItems)"))
        let earlyReturn = try #require(update.range(of: "\n                return\n", range: blockedCase.upperBound..<update.endIndex))
        // ARCH-08 — the mutation phase is the four lanes starting at once; the cask one
        // among them is what reaches brew.
        let brew = try #require(update.range(
            of: "let laneOutputs = await runBoundedOnMainActor(limit: 0, lanes)"))
        #expect(blockedCase.lowerBound < record.lowerBound)
        #expect(record.lowerBound < report.lowerBound)
        #expect(report.lowerBound < earlyReturn.lowerBound)
        #expect(earlyReturn.lowerBound < brew.lowerBound,
                "SEC-02: the mismatch must be displayed before the mutation phase")
    }

    @Test(arguments: [false, true])
    func journalFailurePreservesPublisherVetoBeforeOrAfterSnapshot(afterSnapshot: Bool) throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/ScanStore+Rollback.swift"),
            encoding: .utf8
        )
        let veto = try #require(source.range(of: "let publisherVetoes = CaskRollbackGuard.publisherVetoes("))
        let snapshot = try #require(source.range(of: "let snapshots = snapshotCasks("))
        let missing = try #require(source.range(of: "let missing = caskNames.filter"))
        let section = afterSnapshot
            ? source[snapshot.upperBound..<missing.lowerBound]
            : source[veto.upperBound..<snapshot.lowerBound]
        let persisted = try #require(section.range(of: "try operation.requirePersisted()"))
        let caught = try #require(section.range(of: "catch {", range: persisted.upperBound..<section.endIndex))
        let catchEnd = try #require(section.range(of: "}", range: caught.upperBound..<section.endIndex))
        let failure = section[caught.upperBound..<catchEnd.lowerBound]
        let report = try #require(failure.range(of: "reportJournalFailure(error)"))
        let blocked = try #require(failure.range(of: "return .blocked(publisherVetoes: publisherVetoes)"))
        #expect(report.lowerBound < blocked.lowerBound)
    }
}
