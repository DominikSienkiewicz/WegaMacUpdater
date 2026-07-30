import Foundation
import Testing
@testable import MacUpdaterCore

/// QA-01e — regression coverage for **crash / power loss between phases** (the guarantee
/// fixed in LT-01).
///
/// A cask upgrade runs in phases: Homebrew uninstalls the old artifact and then stages the
/// new one. If power is lost — or the process is killed — *between* those phases, the cask is
/// left half-upgraded: a staged app already occupies the Caskroom destination. On the next
/// run Homebrew refuses to continue and bails with
/// `Error: <token>: It seems there is already an App at '…'`. Left alone, that cask fails on
/// every subsequent attempt until someone clears the leftover by hand.
///
/// LT-01's guarantee is that Wega recovers automatically: it recognizes this specific
/// interrupted-upgrade leftover (`BrewUpgradeOutcome.tokensRetryableWithForce`), retries
/// exactly those tokens once with `--force` (`UpdatePlanner.forcedCaskCommand`), which
/// overwrites the leftover and completes, then folds the retry back into the run outcome
/// (`BrewUpgradeOutcome.merging`). A genuinely different failure — an app source that is
/// simply *gone* — must not be mistaken for this and must not be silently retried.
///
/// The decision itself lives in `ScanStore.performUpdate`
/// (`Sources/MacUpdater/ScanStore+Updating.swift`), wired behind live `BrewService` values the
/// app target cannot stand in for in a unit test — exactly the situation
/// `RollbackNetAfterRestoreTests` documents. So this suite exercises the recovery *contract*
/// against the real Core primitives through a Homebrew stand-in, and separately pins the
/// update run to that same shape at source level, so a refactor that drops the recovery is
/// still caught.
@Suite("QA-01e — crash / power loss between phases")
struct QA01ECrashBetweenPhasesTests {

    // MARK: The recovery contract, driven through a Homebrew stand-in

    /// The scenario end to end: a previous upgrade was cut short between phases, so this run's
    /// plain attempt hits the stranded staged app; the auto-recovery retries with `--force`,
    /// which clears the leftover, and the run reports success instead of a permanent failure.
    @Test("An upgrade cut short by power loss between phases self-heals on the next run")
    func interruptedUpgradeRecoversViaForcedRetry() {
        let brew = FakeBrewCaskWorld(states: ["discord": .interruptedUpgradeLeftover])

        let outcome = upgradeWithAutoRecovery(tokens: ["discord"], brew: brew)

        // The interrupted upgrade is recovered, not surfaced as a permanent failure.
        #expect(outcome.isSuccessful)
        #expect(outcome.failedTokens.isEmpty)

        // Recovery genuinely reached the package manager: the plain attempt ran first and hit
        // the leftover, then exactly one forced retry targeting only the stranded token ran.
        #expect(brew.invocations == [
            ["upgrade", "--cask", "--", "discord"],
            ["upgrade", "--cask", "--force", "--", "discord"]
        ])
    }

    /// The boundary that defines "between phases": a cask whose app source is genuinely gone
    /// is a different failure. `--force` cannot conjure a missing app, so recovery must not
    /// fire and must not paper the failure over.
    @Test("A genuinely missing app source is not mistaken for a between-phases leftover")
    func missingSourceDoesNotTriggerRecovery() {
        let brew = FakeBrewCaskWorld(states: ["intellij-idea": .missingAppSource])

        let outcome = upgradeWithAutoRecovery(tokens: ["intellij-idea"], brew: brew)

        #expect(!outcome.isSuccessful)
        #expect(outcome.failedTokens == ["intellij-idea"])
        // No forced retry was attempted — only the single plain upgrade ran.
        #expect(brew.invocations == [["upgrade", "--cask", "--", "intellij-idea"]])
    }

    /// A mixed batch: one cask stranded by a crash between phases recovers, while an unrelated
    /// cask that failed for a non-retryable reason in the same run stays failed. Recovery is
    /// scoped to exactly the between-phases leftover and never widens.
    @Test("Recovery is scoped to the stranded cask and leaves unrelated failures intact")
    func recoveryDoesNotWidenToUnrelatedFailures() {
        let brew = FakeBrewCaskWorld(states: [
            "discord": .interruptedUpgradeLeftover,
            "intellij-idea": .missingAppSource
        ])

        let outcome = upgradeWithAutoRecovery(tokens: ["discord", "intellij-idea"], brew: brew)

        #expect(!outcome.isSuccessful)
        #expect(outcome.failedTokens == ["intellij-idea"])
        // The forced retry named only the stranded token, never the genuinely-failed one.
        #expect(brew.invocations == [
            ["upgrade", "--cask", "--", "discord", "intellij-idea"],
            ["upgrade", "--cask", "--force", "--", "discord"]
        ])
    }

    // MARK: The update run still wires the recovery

    /// The behavioral tests above mirror the recovery decision that `ScanStore.performUpdate`
    /// makes, because that method is wired behind live `BrewService` values a unit test cannot
    /// stand in for. This pins the production code to the same three-step shape — recognize
    /// (`tokensRetryableWithForce`) → retry with force (`forcedCaskCommand`) → fold back
    /// (`merging`), in that order — so removing or reordering the recovery there fails here.
    @Test("The update run wires the between-phases auto-recovery path")
    func updateRunWiresTheAutoRecoveryPath() throws {
        let source = try ScanStoreSources.everything()

        let recognize = try #require(source.range(of: ".tokensRetryableWithForce"))
        let retry = try #require(source.range(of: "UpdatePlanner.forcedCaskCommand"))
        let foldBack = try #require(source.range(of: "BrewUpgradeOutcome.merging"))

        #expect(recognize.lowerBound < retry.lowerBound,
                "the leftover must be recognized before the forced retry is built")
        #expect(retry.lowerBound < foldBack.lowerBound,
                "the forced retry must run before its outcome is folded back into the run")
    }

    // MARK: Fixtures

    /// A minimal stand-in for `brew upgrade --cask` that reproduces the two states LT-01
    /// distinguishes: a cask left half-upgraded by a power loss between phases (a staged app
    /// already occupies the Caskroom, so a plain upgrade bails but a `--force` upgrade clears
    /// it and completes), and a cask whose app source is genuinely gone (no `--force` fixes
    /// it). `--force` mutates the simulated world, so a passing recovery proves the retry
    /// *causes* success rather than merely being reported as such.
    private final class FakeBrewCaskWorld {
        enum State {
            case interruptedUpgradeLeftover
            case missingAppSource
        }

        private var states: [String: State]
        private(set) var invocations: [[String]] = []

        init(states: [String: State]) {
            self.states = states
        }

        func upgrade(_ command: UpdateCommand) -> BrewUpgradeOutcome {
            invocations.append(command.arguments)
            let force = command.arguments.contains("--force")
            let tokens = command.arguments.drop(while: { $0 != "--" }).dropFirst()

            var lines: [String] = []
            var anyFailed = false
            for token in tokens {
                switch states[token] {
                case .interruptedUpgradeLeftover:
                    if force {
                        states[token] = nil
                        lines.append("==> Upgraded \(token)")
                    } else {
                        anyFailed = true
                        lines.append("Error: \(token): It seems there is already an App at "
                            + "'/opt/homebrew/Caskroom/\(token)/0.0.392/\(token).app'.")
                    }
                case .missingAppSource:
                    anyFailed = true
                    lines.append("Error: \(token): It seems the App source "
                        + "'/Applications/\(token).app' is not there.")
                case nil:
                    lines.append("==> Upgraded \(token)")
                }
            }
            return BrewUpgradeOutcome.analyze(
                exitCode: anyFailed ? 1 : 0,
                output: lines.joined(separator: "\n")
            )
        }
    }

    /// Mirrors the auto-recovery decision in `ScanStore.performUpdate`: run the plain cask
    /// upgrade, and if any token failed only because a between-phases leftover is in the way,
    /// retry exactly those tokens once with `--force` and fold the result back in.
    private func upgradeWithAutoRecovery(tokens: [String], brew: FakeBrewCaskWorld) -> BrewUpgradeOutcome {
        let outcome = brew.upgrade(UpdatePlanner.caskUpgradeCommand(tokens: tokens))
        let retryTokens = outcome.tokensRetryableWithForce
        guard !retryTokens.isEmpty else { return outcome }
        let forced = brew.upgrade(UpdatePlanner.forcedCaskCommand(tokens: retryTokens))
        return BrewUpgradeOutcome.merging(original: outcome, forcedRetry: forced, retriedTokens: retryTokens)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
