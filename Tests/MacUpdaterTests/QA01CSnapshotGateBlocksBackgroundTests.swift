import Foundation
import Testing
@testable import MacUpdaterCore

/// QA-01c — regression cover for the BG-01 guarantee: **a missing snapshot blocks the
/// background update**.
///
/// A rollback snapshot is the reason an unattended upgrade is defensible at all — without a
/// confirmed clone there is no safe undo, so the round must touch nothing. This suite pins
/// that scenario at two layers: the pure veto that leaves no token to upgrade when every
/// snapshot failed, and the executor wiring that turns an empty snapshot-backed set into a
/// blocked round *before* any brew mutation runs.
@Suite("QA-01c — missing snapshot blocks background update")
struct QA01CSnapshotGateBlocksBackgroundTests {
    private func backgroundUpdaterSource(file: String = #filePath) throws -> String {
        let packageRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MacUpdater/BackgroundUpdater.swift"),
            encoding: .utf8
        )
    }

    /// The mechanism: when `clonefile` fails for every candidate the snapshot map is empty,
    /// so the veto returns no token — there is nothing left for the background round to run.
    /// Fails if `snapshotBackedTokens` ever stops gating on a confirmed snapshot.
    @Test func noCandidateSurvivesWhenEverySnapshotFailed() {
        let lockedTokens = ["figma", "slack", "cursor"]

        #expect(BackgroundUpdateSafety.snapshotBackedTokens(lockedTokens, snapshots: [:]).isEmpty)
    }

    /// The wiring: the snapshot filter feeds the empty-set guard, which logs the skip and
    /// returns before `runBrew`. Fails if the guard is removed or reordered so an unattended
    /// upgrade could reach brew with no rollback net.
    @Test func emptySnapshotBackedSetBlocksTheRoundBeforeBrewRuns() throws {
        let source = try backgroundUpdaterSource()

        let snapshotFilter = try #require(source.range(
            of: "let tokens = BackgroundUpdateSafety.snapshotBackedTokens(lockedTokens, snapshots: snapshots)"
        ))
        let blockGuard = try #require(source.range(of: "guard !tokens.isEmpty else"))
        let skipLog = try #require(source.range(
            of: "Aktualizacja w tle pominięta — nie udało się utworzyć snapshotu."
        ))
        let brew = try #require(source.range(of: "await runBrew(arguments: arguments)"))

        #expect(snapshotFilter.lowerBound < blockGuard.lowerBound)
        #expect(blockGuard.lowerBound < skipLog.lowerBound)
        #expect(skipLog.lowerBound < brew.lowerBound)
        #expect(source[blockGuard.lowerBound ..< brew.lowerBound].contains("return []"))
    }
}
