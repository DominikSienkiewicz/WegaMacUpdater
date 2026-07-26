import Testing
import Foundation
@testable import MacUpdaterCore

/// QA-01b — regression guard for the REL-02 scenario listed as the second of QA-01's
/// "🎯 Najważniejsze nowe scenariusze": **błąd MAS / rollbacku / reskanu nie daje sukcesu**.
///
/// REL-02 made `UpdateRunOutcome` the single place that answers "was this updated?", and its
/// one success gate is `UpdateRunSummary.allItemsUpgraded`. Three failure sources used to
/// slip past that gate into a green banner: a `mas upgrade` that threw, a cask that had to
/// be rolled back, and a post-upgrade rescan that could not confirm the result. This suite
/// pins the guarantee for each of the three, and — the case no single QA-01 test covers —
/// for all three occurring together in one round.
@Suite("QA-01b — błąd MAS / rollbacku / reskanu nie daje sukcesu")
struct QA01BUpgradeOutcomeFailureTests {

    private func formula(_ name: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: .formula), name: name,
                     from: "1.0", to: "2.0", kind: .formula)
    }

    private func cask(_ name: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: .cask), name: name,
                     from: "1.0", to: "2.0", kind: .cask)
    }

    private func masApp(id: String, name: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: id, kind: .appStore), name: name,
                     from: "1.0", to: "2.0", kind: .appStore)
    }

    private let cleanBrew = BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])

    // MARK: The three failure sources, each on its own

    /// „błąd MAS" — a `mas upgrade` that threw is a failure, not a silent log line.
    @Test func masUpgradeErrorIsNotSuccess() {
        var run = UpdateRunOutcome()
        run.record(masItems: [masApp(id: "497799835", name: "Xcode")],
                   failure: "mas upgrade failed with exit code 1")

        let summary = run.summary
        #expect(!summary.allItemsUpgraded)
        #expect(summary.upgraded.isEmpty)
        #expect(summary.notUpgraded.map(\.name) == ["Xcode"])
    }

    /// „rollback" — a cask restored to its previous version did not end up upgraded.
    @Test func caskRollbackIsNotSuccess() {
        var run = UpdateRunOutcome()
        run.record([cask("figma")], outcome: cleanBrew)
        run.applyValidation(["figma": .rolledBack])

        #expect(!run.summary.allItemsUpgraded)
        #expect(run.summary.notUpgraded.map(\.name) == ["figma"])
    }

    /// „rollback" at its worst — a rollback that itself failed is the case REL-02 calls
    /// "the one that must never be silent": no success, and it must be critical.
    @Test func failedCaskRollbackIsNotSuccessAndCritical() {
        var run = UpdateRunOutcome()
        run.record([cask("figma")], outcome: cleanBrew)
        run.applyValidation(["figma": .rollbackFailed])

        let summary = run.summary
        #expect(!summary.allItemsUpgraded)
        #expect(summary.critical.map(\.name) == ["figma"])
    }

    /// „reskan" — the fresh scan still lists the item, so the tool's claim is not trusted.
    @Test func itemStillOutdatedAfterRescanIsNotSuccess() {
        var run = UpdateRunOutcome()
        run.record([formula("wget")], outcome: cleanBrew)
        run.applyRescan(stillOutdatedKeys: [UpdatePlanner.key(name: "wget", kind: .formula)],
                        confirmed: true)

        #expect(!run.summary.allItemsUpgraded)
        #expect(run.summary.notUpgraded.map(\.name) == ["wget"])
    }

    /// „reskan" that could not run — an upgrade left unverified is not a verified one.
    @Test func unconfirmedRescanIsNotSuccess() {
        var run = UpdateRunOutcome()
        run.record([formula("wget")], outcome: cleanBrew)
        run.applyRescan(stillOutdatedKeys: [], confirmed: false)

        #expect(!run.summary.allItemsUpgraded)
        #expect(run.summary.notUpgraded.map(\.name) == ["wget"])
    }

    // MARK: All three at once — the scenario as one round

    /// The whole scenario in a single run: a MAS error, a cask rollback and a rescan that
    /// still reports its formula. None of the three may count as upgraded, and the run as a
    /// whole must not read as success — the failures must not cancel each other out or be
    /// masked by the shared summary gate.
    @Test func masErrorRollbackAndRescanFailureTogetherAreNotSuccess() {
        var run = UpdateRunOutcome()
        run.record([formula("wget"), cask("figma")], outcome: cleanBrew)
        run.record(masItems: [masApp(id: "497799835", name: "Xcode")], failure: "boom")
        run.applyValidation(["figma": .rolledBack])
        run.applyRescan(stillOutdatedKeys: [UpdatePlanner.key(name: "wget", kind: .formula)],
                        confirmed: true)

        let summary = run.summary
        #expect(!summary.allItemsUpgraded,
                "REL-02: a run with a MAS error, a rollback and a failed rescan is not a success")
        #expect(summary.upgraded.isEmpty)
        #expect(Set(summary.notUpgraded.map(\.name)) == ["Xcode", "figma", "wget"])
    }

    // MARK: The gate is not vacuous

    /// The same three sources, all clean, must still be able to reach success — otherwise
    /// every assertion above would hold no matter what the production code did, and the
    /// suite would guard nothing.
    @Test func theSameSourcesSucceedWhenNothingFails() {
        var run = UpdateRunOutcome()
        run.record([formula("wget"), cask("figma")], outcome: cleanBrew)
        run.record(masItems: [masApp(id: "497799835", name: "Xcode")], failure: nil)
        run.applyValidation(["figma": .healthy])
        run.applyRescan(stillOutdatedKeys: [], confirmed: true)

        let summary = run.summary
        #expect(summary.allItemsUpgraded)
        #expect(Set(summary.upgraded.map(\.name)) == ["Xcode", "figma", "wget"])
    }
}
