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
}
