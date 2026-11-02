import Foundation
import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

/// The tap-trust button runs one brew command that changes the user's Homebrew
/// configuration, so it takes the same protected path as every other brew write and reports
/// into the same log — under the warning it answers, not in place of it.
///
/// XCTest runs these shared-mutex checks sequentially, separately from Swift Testing suites.
@MainActor
final class TapTrustRemedyRunTests: XCTestCase {
    private static let warning = [
        "Homebrew is currently ignoring formulae, casks and commands",
        "from these taps because tap trust is required.",
        "Untap them with:",
        "  brew untap manaflow-ai/cmux",
    ]

    func testGivenTheWarningWhenTheUntapRemedyRunsThenExactlyItsCommandRunsAndReportsUnderTheWarning() async {
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

        XCTAssertEqual(runner.requests.map(\.arguments), [["untap", "--", "manaflow-ai/cmux"]])
        XCTAssertEqual(harness.store.brewLog, Self.warning + ["$ brew untap -- manaflow-ai/cmux", "Untapping manaflow-ai/cmux..."])
        XCTAssertTrue(harness.store.showLog)
        XCTAssertEqual(harness.store.banner?.variant, .success)
        XCTAssertTrue(TapTrustPlanner.pending([remedy], in: harness.store.brewLog).isEmpty,
                "the button just clicked must not be offered again")
    }

    func testGivenBrewFailsWhenARemedyRunsThenTheBannerSaysSoAndPointsAtTheLog() async {
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

        XCTAssertEqual(runner.requests.map(\.arguments), [["untap", "--", "manaflow-ai/cmux"]])
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertEqual(harness.store.banner?.title, tr("Nie udało się zmienić tapów"))
        XCTAssertEqual(harness.store.brewLog.last, "Error: No available tap manaflow-ai/cmux.")
    }
}
