import Testing
@testable import MacUpdaterCore

/// BG-01 follow-up — a failed unattended batch and its canary result are independent facts.
/// Global process failure keeps every token out of `upgraded`, while an app that was already
/// mutated must still report a rollback or publisher change discovered afterwards.
@Suite("Background global failure validation")
struct BackgroundGlobalFailureValidationTests {
    private func item(_ name: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: .cask), name: name,
                     from: "1.0", to: "2.0", kind: .cask)
    }

    @Test func globalFailurePreservesPublisherChangeAndRollbackSignals() {
        var run = UpdateRunOutcome()
        run.recordBackgroundRound(
            [item("figma"), item("slack")],
            outcome: BrewUpgradeOutcome(exitCode: 1, failedTokens: ["slack"],
                                        errorLines: ["Error: slack: boom"])
        )

        run.applyValidation([
            "figma": .publisherChanged(old: "OLDTEAM", new: "NEWTEAM"),
            "slack": .rolledBack,
        ])

        let summary = run.summary
        #expect(summary.upgraded.isEmpty, "A non-zero global exit must still invalidate every token")
        #expect(summary.notUpgraded.map(\.name) == ["figma", "slack"])
        #expect(summary.items.map(\.verdict) == [
            .executionFailedWithPublisherChange(old: "OLDTEAM", new: "NEWTEAM"),
            .executionFailedAfterRollback,
        ])
        #expect(summary.publisherChanges.map(\.name) == ["figma"])
        #expect(summary.publisherChanges.map(\.verdict) == [
            .publisherChanged(old: "OLDTEAM", new: "NEWTEAM"),
        ])
        #expect(summary.critical.map(\.name) == ["figma"])
        #expect(summary.names { $0 == .rolledBack } == ["slack"])
        #expect(summary.names { $0 == .executionFailed } == ["figma", "slack"])
    }
}
