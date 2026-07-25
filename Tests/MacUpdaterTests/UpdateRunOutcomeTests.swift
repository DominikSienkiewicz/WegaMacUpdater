import Testing
import Foundation
@testable import MacUpdaterCore

/// REL-02 — "success" must mean every phase of the operation succeeded.
///
/// Six independent paths used to end in the same lie: a green banner over a failed run.
/// A `mas upgrade` that threw reached the collapsible log and never became an outcome; the
/// cask result was summarized *before* the canary ran and `postCaskUpgrade` returned
/// nothing; the summary only ever saw `BrewUpgradeOutcome`, so no validation verdict could
/// enter it; `.rollbackFailed` — the case the code itself calls "the one that must never be
/// silent" — was a line in a collapsed log under a green banner; and nothing re-checked
/// whether the item was actually gone from the outdated list afterwards.
///
/// These tests pin the contract at the one place that now answers the question: a single
/// outcome per item and source, covering execution, validation, rollback **and** rescan.
@Suite("UpdateRunOutcome")
struct UpdateRunOutcomeTests {

    private func item(_ name: String, kind: OutdatedItem.Kind) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: kind), name: name,
                     from: "1.0", to: "2.0", kind: kind)
    }

    private func masItem(id: String, name: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: id, kind: .appStore), name: name,
                     from: "1.0", to: "2.0", kind: .appStore)
    }

    private let cleanBrew = BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])

    // MARK: Execution — MAS

    /// Path 1: `mas upgrade` threw. It used to be appended to the log and nowhere else, so
    /// the run had no outcome to be unhappy about and the banner said "Wszystko gotowe".
    @Test func failedMasUpgradeIsNotSuccess() {
        var run = UpdateRunOutcome()
        run.record(masItems: [masItem(id: "497799835", name: "Xcode")],
                   failure: "mas upgrade failed with exit code 1")

        let summary = run.summary
        #expect(!summary.allItemsUpgraded, "REL-02: a mas upgrade that threw must not read as success")
        #expect(summary.upgraded.isEmpty)
        #expect(summary.notUpgraded.map(\.name) == ["Xcode"])
        #expect(summary.diagnostics.contains { $0.contains("mas upgrade") })
    }

    @Test func successfulMasUpgradeIsSuccess() {
        var run = UpdateRunOutcome()
        run.record(masItems: [masItem(id: "497799835", name: "Xcode")], failure: nil)

        #expect(run.summary.allItemsUpgraded)
        #expect(run.summary.upgraded.map(\.name) == ["Xcode"])
    }

    /// A MAS failure must not be swallowed by the successes around it either.
    @Test func failedMasUpgradeSurvivesAlongsideSucceedingSources() {
        var run = UpdateRunOutcome()
        run.record([item("wget", kind: .formula)], outcome: cleanBrew)
        run.record(masItems: [masItem(id: "1", name: "Xcode")], failure: "boom")

        let summary = run.summary
        #expect(!summary.allItemsUpgraded)
        #expect(summary.upgraded.map(\.name) == ["wget"])
        #expect(summary.notUpgraded.map(\.name) == ["Xcode"])
    }

    // MARK: Validation & rollback

    /// Paths 2–4: the cask outcome reached the summary before the canary had run, and the
    /// verdict had no way into it afterwards. A failed rollback ended in a green banner.
    @Test func rollbackFailureIsNotSuccessAndIsCritical() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask)], outcome: cleanBrew)
        run.applyValidation(["figma": .rollbackFailed])

        let summary = run.summary
        #expect(!summary.allItemsUpgraded, "REL-02: a failed rollback must never read as success")
        #expect(summary.rollbackFailures.map(\.name) == ["figma"])
        #expect(summary.critical.map(\.name) == ["figma"],
                "REL-02: a failed rollback earns a sticky banner, not a line in a collapsed log")
    }

    /// A rolled-back cask is on its *old* version: the upgrade did not happen.
    @Test func rolledBackCaskIsNotSuccess() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask)], outcome: cleanBrew)
        run.applyValidation(["figma": .rolledBack])

        #expect(!run.summary.allItemsUpgraded)
        #expect(run.summary.notUpgraded.map(\.name) == ["figma"])
        #expect(run.summary.critical.isEmpty, "A completed rollback is handled — it is not the emergency")
    }

    /// The upgrade did happen, so it counts as upgraded — but a changed Team ID is exactly
    /// the signal the summary banner used to overwrite on its way out.
    @Test func publisherChangeIsUpgradedButCritical() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask)], outcome: cleanBrew)
        run.applyValidation(["figma": .publisherChanged(old: "AAA", new: "BBB")])

        let summary = run.summary
        #expect(summary.allItemsUpgraded)
        #expect(summary.publisherChanges.map(\.name) == ["figma"])
        #expect(summary.critical.map(\.name) == ["figma"])
    }

    @Test func healthyValidationLeavesTheExecutionVerdictAlone() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask)], outcome: cleanBrew)
        run.applyValidation(["figma": .healthy])

        #expect(run.summary.allItemsUpgraded)
    }

    /// The canary sees the *old* bundle when brew never replaced it, and it passes
    /// Gatekeeper — a `.healthy` verdict must not talk a failed install back up to success.
    @Test func validationCannotUpgradeAFailedInstallToSuccess() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask)],
                   outcome: BrewUpgradeOutcome(exitCode: 1, failedTokens: ["figma"],
                                               errorLines: ["Error: figma: It seems the App source is not there."]))
        run.applyValidation(["figma": .healthy])

        #expect(!run.summary.allItemsUpgraded)
        #expect(run.summary.notUpgraded.map(\.name) == ["figma"])
    }

    // MARK: Rescan

    /// The last required phase: brew claimed to have upgraded it, the fresh scan still
    /// lists it. Nothing re-checked this, so the banner believed the tool.
    @Test func itemStillOutdatedAfterTheRescanIsNotSuccess() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask)], outcome: cleanBrew)
        run.applyRescan(stillOutdatedKeys: [UpdatePlanner.key(name: "figma", kind: .cask)], confirmed: true)

        #expect(!run.summary.allItemsUpgraded, "REL-02: an item the rescan still reports is not updated")
        #expect(run.summary.notUpgraded.map(\.name) == ["figma"])
    }

    /// A rescan that could not run leaves the upgrade unconfirmed — which is not the same
    /// as confirmed-good, and must not be reported as such.
    @Test func unconfirmedRescanIsNotSuccess() {
        var run = UpdateRunOutcome()
        run.record([item("wget", kind: .formula)], outcome: cleanBrew)
        run.applyRescan(stillOutdatedKeys: [], confirmed: false)

        #expect(!run.summary.allItemsUpgraded, "REL-02: an unverified upgrade is not a verified one")
        #expect(run.summary.notUpgraded.map(\.name) == ["wget"])
    }

    @Test func cleanRescanConfirmsTheRun() {
        var run = UpdateRunOutcome()
        run.record([item("wget", kind: .formula)], outcome: cleanBrew)
        run.applyRescan(stillOutdatedKeys: [], confirmed: true)

        #expect(run.summary.allItemsUpgraded)
        #expect(run.summary.upgraded.map(\.name) == ["wget"])
    }

    /// The rescan must not undo what an earlier phase already decided: an item that was
    /// rolled back is of course still outdated, and it stays a rollback in the report.
    @Test func rescanDoesNotOverwriteAnEarlierFailure() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask)], outcome: cleanBrew)
        run.applyValidation(["figma": .rollbackFailed])
        run.applyRescan(stillOutdatedKeys: [UpdatePlanner.key(name: "figma", kind: .cask)], confirmed: true)

        #expect(run.summary.rollbackFailures.map(\.name) == ["figma"])
    }

    // MARK: Execution — brew / npm

    @Test func namedFailedTokenFailsOnlyThatItem() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask), item("slack", kind: .cask)],
                   outcome: BrewUpgradeOutcome(exitCode: 1, failedTokens: ["figma"],
                                               errorLines: ["Error: figma: boom"]))

        let summary = run.summary
        #expect(summary.upgraded.map(\.name) == ["slack"])
        #expect(summary.notUpgraded.map(\.name) == ["figma"])
        #expect(summary.diagnostics == ["Error: figma: boom"])
    }

    /// brew can fail the whole batch without naming anyone. Then nothing in it succeeded.
    @Test func unattributedBatchFailureFailsEveryItemInIt() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask), item("slack", kind: .cask)],
                   outcome: BrewUpgradeOutcome(exitCode: 1, failedTokens: [], errorLines: []))

        #expect(run.summary.upgraded.isEmpty)
        #expect(run.summary.notUpgraded.count == 2)
        #expect(run.summary.diagnostics.count == 1)
    }

    @Test func sudoPasswordHintSurvivesIntoTheSummary() {
        var run = UpdateRunOutcome()
        run.record([item("figma", kind: .cask)],
                   outcome: BrewUpgradeOutcome(exitCode: 1, failedTokens: ["figma"],
                                               errorLines: ["Error: figma: boom"], requiresSudoPassword: true))

        #expect(run.summary.needsSudoPassword)
    }

    @Test func anEmptyRunClaimsNothing() {
        #expect(UpdateRunOutcome().summary.isEmpty)
        #expect(UpdateRunOutcome().summary.attempted == 0)
    }
}
