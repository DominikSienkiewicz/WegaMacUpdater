import XCTest
@testable import MacUpdaterCore

final class UpdatePlannerTests: XCTestCase {
    private func brew() -> BrewOutdated {
        BrewOutdated(
            formulae: [BrewOutdatedItem(name: "wget", installedVersions: ["1.0"], currentVersion: "1.1")],
            casks: [BrewOutdatedItem(name: "firefox", installedVersions: ["120"], currentVersion: "121")]
        )
    }
    private func mas() -> [MasOutdatedApp] {
        [MasOutdatedApp(appStoreID: "497799835", name: "Xcode", installedVersion: "15.0", currentVersion: "15.1")]
    }
    private func npm() -> [NpmGlobalOutdated] {
        [NpmGlobalOutdated(name: "@openai/codex", installedVersion: "1.0.0", latestVersion: "1.1.0")]
    }

    // MARK: outdatedItems

    func testOutdatedItemsTagsKeysAndPreservesOrder() {
        let items = UpdatePlanner.outdatedItems(brew: brew(), mas: mas(), npm: npm())
        XCTAssertEqual(items.map(\.key), ["f:wget", "c:firefox", "a:497799835", "n:@openai/codex"])
        XCTAssertEqual(items.map(\.kind), [.formula, .cask, .appStore, .npm])
        XCTAssertEqual(items[0].from, "1.0")
        XCTAssertEqual(items[0].to, "1.1")
        XCTAssertEqual(items[3].from, "1.0.0")
        XCTAssertEqual(items[3].to, "1.1.0")
    }

    func testOutdatedItemsWithNilBrewSkipsBrewRows() {
        let items = UpdatePlanner.outdatedItems(brew: nil, mas: mas(), npm: [])
        XCTAssertEqual(items.map(\.key), ["a:497799835"])
    }

    // MARK: plan

    func testEmptySelectionPlansEverything() {
        let keys = UpdatePlanner.outdatedItems(brew: brew(), mas: mas(), npm: npm()).map(\.key)
        let plan = UpdatePlanner.plan(selectedKeys: [], allKeys: keys)
        XCTAssertEqual(plan.formulaNames, ["wget"])
        XCTAssertEqual(plan.caskNames, ["firefox"])
        XCTAssertEqual(plan.npmNames, ["@openai/codex"])
        XCTAssertTrue(plan.includesMas)
        XCTAssertEqual(plan.count, 4)
    }

    func testExplicitSelectionPlansOnlyChosenKeys() {
        let plan = UpdatePlanner.plan(selectedKeys: ["c:firefox", "n:@openai/codex"], allKeys: ["f:wget", "c:firefox"])
        XCTAssertEqual(plan.caskNames, ["firefox"])
        XCTAssertEqual(plan.npmNames, ["@openai/codex"])
        XCTAssertTrue(plan.formulaNames.isEmpty)
        XCTAssertFalse(plan.includesMas)
        XCTAssertEqual(plan.count, 2)
    }

    /// Key generation (outdatedItems) and key routing (plan) must agree — a mismatch
    /// would silently upgrade the wrong packages. This pins the contract end-to-end.
    func testKeysRoundTripThroughPlan() {
        let items = UpdatePlanner.outdatedItems(brew: brew(), mas: mas(), npm: npm())
        let plan = UpdatePlanner.plan(selectedKeys: Set(items.map(\.key)), allKeys: items.map(\.key))
        XCTAssertEqual(Set(plan.formulaNames), ["wget"])
        XCTAssertEqual(Set(plan.caskNames), ["firefox"])
        XCTAssertEqual(Set(plan.npmNames), ["@openai/codex"])
        XCTAssertTrue(plan.includesMas)
    }

    // MARK: selection helpers

    func testSelectAllState() {
        XCTAssertEqual(UpdatePlanner.selectAllState(selectedCount: 0, totalCount: 3), .none)
        XCTAssertEqual(UpdatePlanner.selectAllState(selectedCount: 3, totalCount: 3), .all)
        XCTAssertEqual(UpdatePlanner.selectAllState(selectedCount: 1, totalCount: 3), .partial)
    }

    func testToggledAll() {
        XCTAssertEqual(UpdatePlanner.toggledAll(selected: ["a", "b"], allKeys: ["a", "b"]), [])
        XCTAssertEqual(UpdatePlanner.toggledAll(selected: ["a"], allKeys: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(UpdatePlanner.toggledAll(selected: [], allKeys: ["a", "b"]), ["a", "b"])
    }

    // MARK: dedupedByPriority

    func testDedupeKeepsHighestPrioritySourcePerPath() {
        let path = URL(fileURLWithPath: "/Applications/Codex.app")
        let sparkle = ManualOutdatedApp(name: "Codex", path: path, installedVersion: "1", availableVersion: "2", source: .sparkle)        // priority 1
        let cask = ManualOutdatedApp(name: "Codex", path: path, installedVersion: "1", availableVersion: "2", source: .cask(token: "codex")) // priority 2
        let result = UpdatePlanner.dedupedByPriority([sparkle, cask])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.source, .cask(token: "codex"))
    }

    func testDedupeKeepsDistinctPathsAndSortsByName() {
        let zebra = ManualOutdatedApp(name: "Zebra", path: URL(fileURLWithPath: "/Applications/Zebra.app"),
                                      installedVersion: "1", availableVersion: "2", source: .sparkle)
        let apple = ManualOutdatedApp(name: "Apple", path: URL(fileURLWithPath: "/Applications/Apple.app"),
                                      installedVersion: "1", availableVersion: "2", source: .sparkle)
        XCTAssertEqual(UpdatePlanner.dedupedByPriority([zebra, apple]).map(\.name), ["Apple", "Zebra"])
    }

    // MARK: summarize

    func testSummarizeAggregatesFailuresAndSudo() {
        let ok = BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])
        let failed = BrewUpgradeOutcome(exitCode: 1, failedTokens: ["zoom"], errorLines: ["Error: zoom: boom"], requiresSudoPassword: true)
        let summary = UpdatePlanner.summarize(outcomes: [ok, failed])
        XCTAssertTrue(summary.anyFailure)
        XCTAssertEqual(summary.failedTokens, ["zoom"])
        XCTAssertTrue(summary.needsSudoPassword)
    }

    // MARK: scanState — "up to date" vs "couldn't check"

    func testScanStateUpToDateOnlyWhenNothingFoundAndNothingFailed() {
        XCTAssertEqual(UpdatePlanner.scanState(updateCount: 0, failedChecks: 0), .upToDate)
    }

    func testScanStateCheckFailedWhenNothingFoundButSomethingFailed() {
        XCTAssertEqual(UpdatePlanner.scanState(updateCount: 0, failedChecks: 3), .checkFailed)
    }

    func testScanStateOutdatedWhenFoundAndNoFailures() {
        XCTAssertEqual(UpdatePlanner.scanState(updateCount: 5, failedChecks: 0), .outdated(5))
    }

    func testScanStatePartialFailureWhenFoundAndFailed() {
        XCTAssertEqual(UpdatePlanner.scanState(updateCount: 2, failedChecks: 1), .partialFailure(updates: 2, failed: 1))
    }

    func testSummarizeAllSuccess() {
        let summary = UpdatePlanner.summarize(outcomes: [BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])])
        XCTAssertFalse(summary.anyFailure)
        XCTAssertTrue(summary.failedTokens.isEmpty)
        XCTAssertFalse(summary.needsSudoPassword)
    }

    // Regression: when an upgrade fails, the detailed brew error lines must reach
    // the summary so they can be written to the persistent log. Previously only the
    // failed *token name* was forwarded, so the log read "Aktualizacja niekompletna:
    // discord" with no explanation of *why* it failed.
    func testSummarizeForwardsFailureDetailLines() {
        let failed = BrewUpgradeOutcome(
            exitCode: 1,
            failedTokens: ["discord"],
            errorLines: ["Error: discord: It seems the App source '/Applications/Discord.app' is not there."]
        )
        let summary = UpdatePlanner.summarize(outcomes: [failed])
        XCTAssertEqual(summary.failureDetails, ["Error: discord: It seems the App source '/Applications/Discord.app' is not there."])
    }

    // When brew fails without printing any "Error:" line (non-zero exit, empty
    // errorLines), the summary must still carry *something* actionable — the exit
    // code — instead of leaving the log with no detail at all.
    func testSummarizeSynthesizesDetailWhenNoErrorLines() {
        let failed = BrewUpgradeOutcome(exitCode: 1, failedTokens: [], errorLines: [])
        let summary = UpdatePlanner.summarize(outcomes: [failed])
        XCTAssertEqual(summary.failureDetails.count, 1)
        XCTAssertTrue(summary.failureDetails[0].contains("1"))
    }

    func testSummarizeNoDetailsWhenEverythingSucceeds() {
        let summary = UpdatePlanner.summarize(outcomes: [BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])])
        XCTAssertTrue(summary.failureDetails.isEmpty)
    }
}
