import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// The tap-trust button runs one brew command that changes the user's Homebrew
/// configuration, so it takes the same protected path as every other brew write and reports
/// into the same log — under the warning it answers, not in place of it.
///
/// Serialized: each run takes the process-wide `UpgradeMutex`, and a parallel sibling holding
/// it would turn the other into a "busy" refusal.
@Suite("Tap trust — running a remedy from the brew log panel", .serialized)
@MainActor
struct TapTrustRemedyRunTests {
    private static let warning = [
        "Homebrew is currently ignoring formulae, casks and commands",
        "from these taps because tap trust is required.",
        "Untap them with:",
        "  brew untap manaflow-ai/cmux",
    ]

    @Test func givenTheWarningWhenTheUntapRemedyRunsThenExactlyItsCommandRunsAndReportsUnderTheWarning() async {
        let runner = ScanStoreRuntimeProcessRunner(
            run: { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") },
            events: { _ in
                .success([
                    .stdout("Untapping manaflow-ai/cmux...\n"),
                    .finished(ProcessResult(exitCode: 0, stdout: "", stderr: "")),
                ])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewLog = Self.warning
        let remedy = TapTrustRemedy(kind: .untapUnused, arguments: BrewService.untapArguments(taps: ["manaflow-ai/cmux"]))

        await harness.store.runTapTrustRemedy(remedy)

        #expect(runner.requests.map(\.arguments) == [["untap", "--", "manaflow-ai/cmux"]])
        #expect(harness.store.brewLog == Self.warning + ["$ brew untap -- manaflow-ai/cmux", "Untapping manaflow-ai/cmux..."])
        #expect(harness.store.showLog)
        #expect(harness.store.banner?.variant == .success)
        #expect(TapTrustPlanner.pending([remedy], in: harness.store.brewLog).isEmpty,
                "the button just clicked must not be offered again")
    }

    @Test func givenBrewFailsWhenARemedyRunsThenTheBannerSaysSoAndPointsAtTheLog() async {
        let runner = ScanStoreRuntimeProcessRunner(
            run: { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") },
            events: { _ in
                .success([
                    .stderr("Error: No available tap manaflow-ai/cmux.\n"),
                    .finished(ProcessResult(exitCode: 1, stdout: "", stderr: "")),
                ])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewLog = Self.warning

        await harness.store.runTapTrustRemedy(
            TapTrustRemedy(kind: .untapUnused, arguments: BrewService.untapArguments(taps: ["manaflow-ai/cmux"]))
        )

        #expect(runner.requests.map(\.arguments) == [["untap", "--", "manaflow-ai/cmux"]])
        #expect(harness.store.banner?.variant == .danger)
        #expect(harness.store.banner?.title == tr("Nie udało się zmienić tapów"))
        #expect(harness.store.brewLog.last == "Error: No available tap manaflow-ai/cmux.")
    }
}
