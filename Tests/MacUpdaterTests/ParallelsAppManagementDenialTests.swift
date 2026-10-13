import Testing
@testable import MacUpdaterCore

@Suite("Parallels ownership denial requires App Management")
struct ParallelsAppManagementDenialTests {
    private static let deniedOutput = """
    ==> Fetching downloads for: parallels
    ✔ Cask parallels (27.0.3-58680)
    ==> Upgrading parallels
      27.0.2-58673 -> 27.0.3-58680
    Error: parallels: Cannot change the ownership of '/Applications/Parallels Desktop.app' because your terminal does not have App Management permissions.
    macOS prevents modifying apps without these permissions, even when using `sudo`.
    To fix this: approve the permissions prompt (if one was just shown) or go to
        System Settings → Privacy & Security → App Management and add or enable your terminal.
    Then run this command again.
    ==> Purging files for version 27.0.3-58680 of Cask parallels
    """

    @Test("Homebrew's explicit ownership refusal selects the privacy recovery action", arguments: [Int32(0), 1])
    func recognizesOwnershipDenial(exitCode: Int32) {
        let outcome = BrewUpgradeOutcome.analyze(exitCode: exitCode, output: Self.deniedOutput)

        #expect(outcome.requiresAppManagementPermission)
        #expect(!outcome.isSuccessful)
        #expect(outcome.failedTokens == ["parallels"])
        #expect(!outcome.requiresSudoPassword)
        #expect(outcome.tokensRetryableWithForce.isEmpty)
        #expect(outcome.errorLines.contains("Then run this command again."))
    }

    @Test("Foreground and background summaries retain the denial after validation", arguments: [false, true])
    func summaryRetainsPermissionDenial(background: Bool) {
        let item = OutdatedItem(
            key: UpdatePlanner.key(name: "parallels", kind: .cask),
            name: "parallels", from: "27.0.2-58673", to: "27.0.3-58680", kind: .cask
        )
        let outcome = BrewUpgradeOutcome.analyze(exitCode: 1, output: Self.deniedOutput)
        var run = UpdateRunOutcome()
        if background {
            run.recordBackgroundRound([item], outcome: outcome)
        } else {
            run.record([item], outcome: outcome)
        }
        run.applyValidation(["parallels": .notUpgraded])
        run.applyRescan(stillOutdatedKeys: [item.key], confirmed: true)

        #expect(run.summary.needsAppManagementPermission)
        #expect(run.summary.upgraded.isEmpty)
        #expect(run.summary.items.first?.verdict == .executionFailed)
    }

    @Test("Homebrew's quarantine fallback warning does not turn a successful update into a denial")
    func quarantineWarningIsNotAnOwnershipDenial() {
        let outcome = BrewUpgradeOutcome.analyze(exitCode: 0, output: """
        Warning: Your terminal does not have App Management permissions, so Homebrew will delete and reinstall the app.
        ==> Upgraded 1 outdated package
        """)

        #expect(!outcome.requiresAppManagementPermission)
        #expect(outcome.isSuccessful)
    }

    @Test("An ordinary ownership error is not attributed to App Management")
    func unrelatedOwnershipErrorIsNotFlagged() {
        let outcome = BrewUpgradeOutcome.analyze(exitCode: 1, output: """
        Error: parallels: Cannot change the ownership of '/Applications/Parallels Desktop.app': Permission denied
        """)

        #expect(!outcome.requiresAppManagementPermission)
        #expect(!outcome.isSuccessful)
    }
}
