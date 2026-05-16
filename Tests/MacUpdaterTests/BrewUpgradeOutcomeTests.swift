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
}
