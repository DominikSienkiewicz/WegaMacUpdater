import XCTest
@testable import MacUpdaterCore

final class BrewUpgradeOutcomeTests: XCTestCase {

    // Real-world brew output: cask upgrade prints "==> Upgraded 1 outdated package"
    // at the end even though an Error occurred mid-way. We must not treat this as success.
    func testDetectsErrorEvenWhenBrewReportsUpgradedPackage() {
        let combined = """
        ==> Fetching downloads for: intellij-idea
        ✔ API Source intellij-idea.rb
        ✔ Cask intellij-idea (2026.1.2,261.24374.151)
        ==> Upgrading 1 outdated package:
        intellij-idea 2026.1.1,261.23567.138 -> 2026.1.2,261.24374.151
        ==> Upgrading intellij-idea
          2026.1.1,261.23567.138 -> 2026.1.2,261.24374.151
        Error: intellij-idea: It seems the App source '/Applications/IntelliJ IDEA.app' is not there.
        ==> Purging files for version 2026.1.2,261.24374.151 of Cask intellij-idea
        ==> Upgraded 1 outdated package
        intellij-idea 2026.1.1,261.23567.138 -> 2026.1.2,261.24374.151
        """

        let outcome = BrewUpgradeOutcome.analyze(exitCode: 0, output: combined)

        XCTAssertFalse(outcome.isSuccessful)
        XCTAssertEqual(outcome.failedTokens, ["intellij-idea"])
        XCTAssertEqual(outcome.errorLines.count, 1)
        XCTAssertTrue(outcome.errorLines[0].contains("App source"))
    }

    func testCleanSuccessfulUpgradeReportsSuccess() {
        let combined = """
        ==> Fetching downloads for: ripgrep
        ==> Upgrading ripgrep
        ==> Upgraded 1 outdated package
        ripgrep 14.0.0 -> 14.1.0
        """

        let outcome = BrewUpgradeOutcome.analyze(exitCode: 0, output: combined)

        XCTAssertTrue(outcome.isSuccessful)
        XCTAssertTrue(outcome.failedTokens.isEmpty)
        XCTAssertTrue(outcome.errorLines.isEmpty)
    }

    func testNonZeroExitCodeIsAlwaysFailure() {
        let outcome = BrewUpgradeOutcome.analyze(exitCode: 1, output: "some unexpected failure\n")
        XCTAssertFalse(outcome.isSuccessful)
    }

    func testExtractsTokenFromErrorLineWithColon() {
        let outcome = BrewUpgradeOutcome.analyze(
            exitCode: 0,
            output: "Error: firefox: download failed\nError: some other thing without token\n"
        )
        XCTAssertEqual(outcome.failedTokens, ["firefox"])
        XCTAssertEqual(outcome.errorLines.count, 2)
    }

    // Real-world Zoom upgrade output: brew calls `sudo launchctl ...` and
    // `sudo pkgutil --forget` during the cask's uninstall hook. Without a
    // configured SUDO_ASKPASS helper (Wega runs from GUI, no terminal), every
    // sudo invocation fails, the cask still gets reinstalled, and the parser
    // must surface this as `requiresSudoPassword` so the UI can prompt the user
    // to configure the askpass helper instead of treating it as a hard failure.
    func testDetectsSudoPasswordRequiredFromZoomOutput() {
        let combined = """
        ==> Removing launchctl service us.zoom.updater.login.check
        sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
        sudo: a password is required
        ==> Removing launchctl service us.zoom.ZoomDaemon
        sudo: a password is required
        ==> Uninstalling packages with `sudo` (which may request your password)...
        us.zoom.pkg.videomeeting
        Error: zoom: Broken pipe
        ==> Purging files for version 7.0.5.81138 of Cask zoom
        ==> Upgraded 1 outdated package
        zoom 7.0.0.77593 -> 7.0.5.81138
        """

        let outcome = BrewUpgradeOutcome.analyze(exitCode: 0, output: combined)

        XCTAssertTrue(outcome.requiresSudoPassword)
        XCTAssertEqual(outcome.failedTokens, ["zoom"])
    }

    func testNoSudoFlagWhenNoPasswordPromptInOutput() {
        let outcome = BrewUpgradeOutcome.analyze(
            exitCode: 0,
            output: "==> Upgraded 1 outdated package\nzoom 1.0 -> 2.0\n"
        )
        XCTAssertFalse(outcome.requiresSudoPassword)
    }

    // Real-world Discord-style failure: the headline "Error:" line is generic and
    // the actual cause is on the continuation lines that follow. We must keep those
    // continuation lines so the log explains *why* the upgrade failed — not just
    // that it did. Continuation stops at the next section header ("==>").
    func testCapturesMultiLineErrorBlockForDetail() {
        let combined = """
        ==> Upgrading discord
          0.0.392 -> 0.0.395
        Error: Failure while executing; `/usr/bin/ditto ...` exited with 1. Here's the output:
        ditto: /Applications/Discord.app: Operation not permitted
        Some other context line from brew.
        ==> Purging files for version 0.0.395 of Cask discord
        """

        let outcome = BrewUpgradeOutcome.analyze(exitCode: 1, output: combined)

        XCTAssertFalse(outcome.isSuccessful)
        XCTAssertTrue(outcome.errorLines.contains { $0.contains("Failure while executing") })
        XCTAssertTrue(outcome.errorLines.contains { $0.contains("Operation not permitted") },
                      "continuation line carrying the real cause must be captured")
    }

    // MARK: interrupted-upgrade leftover → force-retry detection

    // Real-world Discord failure (captured live): a previous upgrade died mid-flight
    // and left a staged app in the Caskroom, so brew refuses to proceed. A forced
    // retry overwrites the leftover and completes — so this token is retryable.
    func testDetectsInterruptedUpgradeLeftoverAsRetryable() {
        let combined = """
        ==> Upgrading discord
          0.0.392 -> 0.0.395
        Error: discord: It seems there is already an App at '/opt/homebrew/Caskroom/discord/0.0.392/Discord.app'.
        ==> Purging files for version 0.0.395 of Cask discord
        """

        let outcome = BrewUpgradeOutcome.analyze(exitCode: 1, output: combined)

        XCTAssertEqual(outcome.tokensRetryableWithForce, ["discord"])
    }

    // A missing *source* App ("is not there") is a different failure — --force can't
    // conjure a missing app, so it must NOT be retried.
    func testMissingAppSourceIsNotRetryable() {
        let outcome = BrewUpgradeOutcome.analyze(
            exitCode: 0,
            output: "Error: intellij-idea: It seems the App source '/Applications/IntelliJ IDEA.app' is not there.\n"
        )
        XCTAssertTrue(outcome.tokensRetryableWithForce.isEmpty)
    }

    // MARK: merging a forced retry back into the batch outcome

    func testMergingClearsFailureWhenForcedRetrySucceeds() {
        let original = BrewUpgradeOutcome(
            exitCode: 1, failedTokens: ["discord"],
            errorLines: ["Error: discord: It seems there is already an App at '/opt/homebrew/Caskroom/discord/0.0.392/Discord.app'."]
        )
        let retry = BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])

        let merged = BrewUpgradeOutcome.merging(original: original, forcedRetry: retry, retriedTokens: ["discord"])

        XCTAssertTrue(merged.isSuccessful)
        XCTAssertTrue(merged.failedTokens.isEmpty)
    }

    func testMergingKeepsUnrelatedFailureFromTheBatch() {
        // zoom failed for an unrelated (non-retryable) reason in the same batch.
        let original = BrewUpgradeOutcome(
            exitCode: 1, failedTokens: ["discord", "zoom"],
            errorLines: [
                "Error: discord: It seems there is already an App at '/opt/homebrew/Caskroom/discord/0.0.392/Discord.app'.",
                "Error: zoom: Broken pipe"
            ]
        )
        let retry = BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])

        let merged = BrewUpgradeOutcome.merging(original: original, forcedRetry: retry, retriedTokens: ["discord"])

        XCTAssertFalse(merged.isSuccessful)
        XCTAssertEqual(merged.failedTokens, ["zoom"])
        XCTAssertTrue(merged.errorLines.contains { $0.contains("zoom") })
        XCTAssertFalse(merged.errorLines.contains { $0.contains("discord") },
                       "the retried token's original error must be dropped")
    }

    func testMergingReportsForcedRetryFailure() {
        let original = BrewUpgradeOutcome(
            exitCode: 1, failedTokens: ["discord"],
            errorLines: ["Error: discord: It seems there is already an App at '/opt/homebrew/Caskroom/discord/0.0.392/Discord.app'."]
        )
        let retry = BrewUpgradeOutcome(exitCode: 1, failedTokens: ["discord"],
                                       errorLines: ["Error: discord: still stuck after --force"])

        let merged = BrewUpgradeOutcome.merging(original: original, forcedRetry: retry, retriedTokens: ["discord"])

        XCTAssertFalse(merged.isSuccessful)
        XCTAssertEqual(merged.failedTokens, ["discord"])
        XCTAssertTrue(merged.errorLines.contains { $0.contains("still stuck after --force") })
    }
}
