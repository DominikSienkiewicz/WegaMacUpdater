import Testing
import Foundation
@testable import MacUpdaterCore

/// Running several `brew` processes at once introduces one failure the sequential run could
/// never produce: brew refusing because another brew already holds a lock it needs. Nothing
/// was installed when that happens, so it is the one brew failure that is safe to retry.
@Suite("BrewLockCollision")
struct BrewLockCollisionTests {

    private static let collision = """
    ==> Upgrading figma
    Error: A `brew upgrade --cask figma` process has already locked /opt/homebrew/Caskroom/figma.
    Please wait for it to finish or terminate it to continue.
    """

    @Test func aLockedPathIsRecognised() {
        let outcome = BrewUpgradeOutcome.analyze(exitCode: 1, output: Self.collision)
        #expect(outcome.isHomebrewLockCollision)
    }

    /// An ordinary cask failure must not be retried as if nothing had run — a retry after a
    /// real install failure repeats the failure and doubles the time it costs.
    @Test func anOrdinaryFailureIsNotALockCollision() {
        let output = """
        ==> Upgrading figma
        Error: figma: It seems there is already an App at '/Applications/Figma.app'.
        """
        #expect(!BrewUpgradeOutcome.analyze(exitCode: 1, output: output).isHomebrewLockCollision)
    }

    @Test func aCleanRunIsNotALockCollision() {
        let output = "==> Upgrading figma\nfigma was successfully upgraded!"
        #expect(!BrewUpgradeOutcome.analyze(exitCode: 0, output: output).isHomebrewLockCollision)
    }
}
