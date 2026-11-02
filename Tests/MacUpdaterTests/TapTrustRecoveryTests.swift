import Testing
@testable import MacUpdaterCore

@Suite("Tap trust — recovery from a blocked untap")
struct TapTrustRecoveryTests {
    private let untap = TapTrustRemedy(kind: .untapUnused, arguments: ["untap", "--", "manaflow-ai/cmux", "steipete/tap"])
    private let refusal = "Error: Refusing to load cask manaflow-ai/cmux/cmux from untrusted tap manaflow-ai/cmux."

    @Test func givenTheScreenshotFailureWhenPlanningThenScopedTrustAndUntapRetryRemainAvailable() {
        let log = TapTrustWarningTests.warning + [TapTrustPlanner.logHeader(for: untap), refusal,
            "Run `brew trust --cask manaflow-ai/cmux/cmux` or `brew trust manaflow-ai/cmux` to trust it."]

        #expect(TapTrustPlanner.pending([untap], in: log).map(\.arguments) == [
            ["trust", "--cask", "--", "manaflow-ai/cmux/cmux"], untap.arguments,
        ])
    }

    @Test func givenARefusalWithoutTheEarlierWarningWhenReadingThenItsTapIsRecognized() {
        #expect(TapTrustWarning.untrustedTaps(in: ["[brew] " + refusal]) == ["manaflow-ai/cmux"])
    }

    @Test func givenAWarningDuringUntapWhenRefusedThenTheActiveCommandIsRetained() {
        let log = [TapTrustPlanner.logHeader(for: untap)] + TapTrustWarningTests.warning + [refusal]

        #expect(TapTrustPlanner.pending([untap], in: log).map(\.arguments) == [
            ["trust", "--cask", "--", "manaflow-ai/cmux/cmux"], untap.arguments,
        ])
    }

    @Test func givenAFormulaRefusalWhenPlanningThenOnlyThatFormulaCanBeTrusted() {
        let log = [TapTrustPlanner.logHeader(for: untap),
            "Error: Refusing to load formula steipete/tap/peekaboo from untrusted tap steipete/tap."]

        #expect(TapTrustPlanner.pending([untap], in: log).map(\.arguments) == [
            ["trust", "--formula", "--", "steipete/tap/peekaboo"], untap.arguments,
        ])
    }

    @Test func givenFailedOrUnfinishedCommandsWhenPlanningThenUntapIsStillPending() {
        for output in [[], ["Error: No available tap manaflow-ai/cmux."]] {
            let log = TapTrustWarningTests.warning + [TapTrustPlanner.logHeader(for: untap)] + output
            #expect(TapTrustPlanner.pending([untap], in: log) == [untap])
        }
    }

    @Test func givenSuccessfulTrustWhenPlanningThenUntapStillNeedsItsOwnClick() {
        let log = [TapTrustPlanner.logHeader(for: untap), refusal,
            "$ brew trust --cask -- manaflow-ai/cmux/cmux",
            "[wega] succeeded: brew trust --cask -- manaflow-ai/cmux/cmux"]

        #expect(TapTrustPlanner.pending([untap], in: log) == [untap])
        #expect(TapTrustPlanner.pending([untap], in: log + [
            TapTrustPlanner.logHeader(for: untap), "[wega] succeeded: " + untap.commandLine,
        ]).isEmpty)
    }

    @Test func givenTheRefusalAgainAfterTrustWhenPlanningThenTrustIsOfferedAgain() {
        let log = [TapTrustPlanner.logHeader(for: untap), refusal,
            "$ brew trust --cask -- manaflow-ai/cmux/cmux",
            "[wega] succeeded: brew trust --cask -- manaflow-ai/cmux/cmux",
            TapTrustPlanner.logHeader(for: untap), refusal]

        #expect(TapTrustPlanner.pending([untap], in: log).map(\.arguments) == [
            ["trust", "--cask", "--", "manaflow-ai/cmux/cmux"], untap.arguments,
        ])
    }

    @Test func givenUnrelatedOrUnsafeOutputWhenPlanningThenNoTrustActionIsInvented() {
        let rejected = [
            "Error: Refusing to load cask evil/tap/cmux from untrusted tap manaflow-ai/cmux.",
            "Error: Refusing to load cask evil/tap/cmux from untrusted tap evil/tap.",
            "Error: Refusing to load cask manaflow-ai/cmux/--force from untrusted tap manaflow-ai/cmux.",
            "Error: Refusing to load cask manaflow-ai/cmux/../../etc from untrusted tap manaflow-ai/cmux.",
            "Error: Refusing to load command manaflow-ai/cmux/run from untrusted tap manaflow-ai/cmux.",
            "Run `brew trust manaflow-ai/cmux` to trust it.",
        ]
        for line in rejected {
            #expect(TapTrustPlanner.pending([untap], in: [TapTrustPlanner.logHeader(for: untap), line]) == [untap])
        }
        #expect(TapTrustPlanner.pending([untap], in: [refusal]) == [untap])
        #expect(TapTrustPlanner.pending([untap], in: ["$ brew upgrade --cask -- cmux", refusal]) == [untap])
        #expect(TapTrustPlanner.pending([untap], in: [
            TapTrustPlanner.logHeader(for: untap), "$ brew upgrade --cask -- cmux", refusal,
        ]) == [untap])
    }
}
