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
        XCTAssertEqual(harness.store.brewLog, Self.warning + ["$ brew untap -- manaflow-ai/cmux", "Untapping manaflow-ai/cmux...",
            "[wega] succeeded: brew untap -- manaflow-ai/cmux"])
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
        let remedy = TapTrustRemedy(kind: .untapUnused, arguments: BrewService.untapArguments(taps: ["manaflow-ai/cmux"]))
        XCTAssertEqual(TapTrustPlanner.pending([remedy], in: harness.store.brewLog), [remedy])
    }

    func testGivenATrustBlockedUntapWhenRecoveringThenTrustAndRetryRequireSeparateInvocations() async throws {
        let untap = TapTrustRemedy(kind: .untapUnused, arguments: BrewService.untapArguments(taps: ["manaflow-ai/cmux"]))
        let runner = ScanStoreRuntimeProcessRunner(
            run: { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") },
            events: { request in
                if request.arguments.first == "untap" {
                    return .success([
                        .stderr("Error: Refusing to load cask manaflow-ai/cmux/cmux from untrusted tap manaflow-ai/cmux.\n"),
                        .finished(ProcessResult(exitCode: 1, stdout: "", stderr: "")),
                    ])
                }
                return .success([.finished(ProcessResult(exitCode: 0, stdout: "", stderr: ""))])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewLog = Self.warning

        await harness.store.runTapTrustRemedy(untap)

        XCTAssertEqual(runner.requests.map(\.arguments), [untap.arguments], "a failure must never auto-trust or retry")
        let pending = TapTrustPlanner.pending([untap], in: harness.store.brewLog)
        let trust = try XCTUnwrap(pending.first { $0.arguments.first == "trust" })
        XCTAssertEqual(trust.arguments, ["trust", "--cask", "--", "manaflow-ai/cmux/cmux"])
        let presentation = TapTrustRemedyPresentation(trust)
        XCTAssertEqual(presentation.buttonTitle, tr("Zaufaj definicji caska"))
        XCTAssertEqual(presentation.explanation, tr("Homebrew wymaga tej definicji przy odpinaniu tapu. Zaufanie pozostanie zapisane; potem ponów odpięcie."))

        await harness.store.runTapTrustRemedy(trust)

        XCTAssertEqual(runner.requests.map(\.arguments), [untap.arguments, trust.arguments])
        XCTAssertEqual(TapTrustPlanner.pending([untap], in: harness.store.brewLog), [untap])
        XCTAssertEqual(harness.store.banner?.title, tr("Zaufano wskazanej definicji pakietu"))
    }

    func testGivenTwoUnusedTapsWhenTheSecondFailsThenRetryDoesNotIncludeTheRemovedTap() async {
        let runner = ScanStoreRuntimeProcessRunner(
            run: { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") },
            events: { request in
                if request.arguments.contains("steipete/tap") {
                    return .success([
                        .stderr("from these taps because tap trust is required.\nUntap them with:\n  brew untap steipete/tap\n"),
                        .stderr("Error: Refusing to load cask steipete/tap/codexbar from untrusted tap steipete/tap.\n"),
                        .finished(ProcessResult(exitCode: 1, stdout: "", stderr: "")),
                    ])
                }
                return .success([.finished(ProcessResult(exitCode: 0, stdout: "", stderr: ""))])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewLog = Self.warning
        let remedies = TapTrustPlanner.remedies(forUntrustedTaps: ["manaflow-ai/cmux", "steipete/tap"], installed: [])

        for remedy in remedies {
            await harness.store.runTapTrustRemedy(remedy)
        }

        XCTAssertEqual(runner.requests.map(\.arguments), [
            ["untap", "--", "manaflow-ai/cmux"], ["untap", "--", "steipete/tap"],
        ])
        XCTAssertEqual(TapTrustPlanner.pending(remedies, in: harness.store.brewLog).map(\.arguments), [
            ["trust", "--cask", "--", "steipete/tap/codexbar"], ["untap", "--", "steipete/tap"],
        ])
    }
}
