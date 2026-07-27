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
        // The preparation half moved to the Rollback split (file length), the run it
        // feeds stayed in Actions — the ordering this pins spans both.
        let rollback = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/ScanStore+Rollback.swift"),
            encoding: .utf8
        )
        let actions = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/ScanStore+Actions.swift"),
            encoding: .utf8
        )
        let source = rollback + "\n" + actions

        let preparationStart = try #require(source.range(of: "func prepareForegroundCasks("))
        let preparationEnd = try #require(source.range(
            of: "func foregroundResourceDecision(",
            range: preparationStart.upperBound..<source.endIndex
        ))
        let preparation = source[preparationStart.lowerBound..<preparationEnd.lowerBound]
        let veto = try #require(preparation.range(
            of: "let publisherVetoes = CaskRollbackGuard.publisherVetoes("))
        let snapshot = try #require(preparation.range(of: "let snapshots = snapshotCasks("))
        let blocked = try #require(preparation.range(
            of: "return .blocked(publisherVetoes: publisherVetoes)"))
        #expect(veto.lowerBound < snapshot.lowerBound)
        #expect(snapshot.lowerBound < blocked.lowerBound)

        let updateStart = try #require(source.range(of: "func runUpdate(targetKeys: Set<String>) async"))
        let updateEnd = try #require(source.range(
            of: "private func report(run: UpdateRunOutcome)",
            range: updateStart.upperBound..<source.endIndex
        ))
        let update = source[updateStart.lowerBound..<updateEnd.lowerBound]
        let blockedCase = try #require(update.range(of: "case .blocked(let publisherVetoes):"))
        let record = try #require(update.range(of: "blockedRun.recordPublisherVetoes("))
        let report = try #require(update.range(of: "report(run: blockedRun)"))
        let brew = try #require(update.range(
            of: "var caskOutcome = await runBrewUpgrade(arguments: trustedCaskArgs)"))
        #expect(blockedCase.lowerBound < record.lowerBound)
        #expect(record.lowerBound < report.lowerBound)
        #expect(report.lowerBound < brew.lowerBound,
                "SEC-02: the mismatch must be displayed before the mutation phase")
    }
}
