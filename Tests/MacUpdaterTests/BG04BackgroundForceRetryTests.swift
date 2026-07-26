import Foundation
import Testing
@testable import MacUpdaterCore

/// BG-04 — the unattended round must recover a between-phases leftover the same way the
/// window does, instead of failing it silently on every round.
///
/// The window auto-heals an interrupted cask upgrade (a staged app left behind by a
/// cut-short previous run, `Error: <token>: … already an App at …`) with a single `--force`
/// retry (`QA01ECrashBetweenPhasesTests`). The background path had no such recovery: the
/// leftover failed the token on **every** scheduled round, forever, and — before the token
/// is cleared by hand — did so as a repeating event rather than a one-time one.
///
/// This fixes that by reusing the same three Core primitives the window uses — recognize
/// (`BrewUpgradeOutcome.tokensRetryableWithForce`) → retry with force
/// (`UpdatePlanner.forcedCaskCommand`) → fold back (`BrewUpgradeOutcome.merging`) — and then
/// records the merged outcome through the unattended-specific `recordBackgroundRound`, whose
/// failure count is exactly what the notification renders.
///
/// `BackgroundUpdater.runIfEligible` is wired behind live `BrewService` / coordinator /
/// notification-center values the app target cannot stand in for in a unit test — the same
/// situation `QA01ECrashBetweenPhasesTests` documents. So this suite exercises the recovery
/// *contract* against the real Core primitives through a Homebrew stand-in, and separately
/// pins the production round to that same shape at source level.
@Suite("BG-04 — background round forced retry")
struct BG04BackgroundForceRetryTests {

    // MARK: The unattended recovery contract, driven through a Homebrew stand-in

    /// The bug, stated as a fact: without a forced retry the between-phases leftover fails the
    /// token and nothing tries to clear it, so the identical failure recurs next round.
    @Test("Without a forced retry a between-phases leftover fails on every background round")
    func leftoverFailsEveryRoundWithoutRetry() {
        let brew = FakeBrewCaskWorld(states: ["discord": .interruptedUpgradeLeftover])

        var run = UpdateRunOutcome()
        run.recordBackgroundRound(
            [caskItem("discord")],
            outcome: brew.upgrade(UpdatePlanner.caskUpgradeCommand(tokens: ["discord"]))
        )

        #expect(run.summary.upgraded.isEmpty)
        #expect(run.summary.notUpgraded.map(\.name) == ["discord"])
        #expect(brew.invocations == [["upgrade", "--cask", "--", "discord"]],
                "no recovery ran, so the same leftover recurs on the next round")
    }

    /// The fix: the leftover is recovered by exactly one `--force` retry, scoped to the
    /// stranded token, and the round then reports the cask as upgraded — it stops failing.
    @Test("A background round recovers a between-phases leftover with a single forced retry")
    func leftoverRecoversViaSingleForcedRetry() {
        let brew = FakeBrewCaskWorld(states: ["discord": .interruptedUpgradeLeftover])

        let run = unattendedRoundWithAutoRecovery(tokens: ["discord"], brew: brew)

        #expect(run.summary.upgraded.map(\.name) == ["discord"])
        #expect(run.summary.notUpgraded.isEmpty)
        #expect(brew.invocations == [
            ["upgrade", "--cask", "--", "discord"],
            ["upgrade", "--cask", "--force", "--", "discord"],
        ], "exactly one forced retry, scoped to the stranded token")
    }

    /// The boundary that defines "between phases": a cask whose app source is genuinely gone
    /// is a different failure `--force` cannot fix, so recovery must not fire for it.
    @Test("A genuinely missing app source is never force-retried in the background")
    func missingSourceIsNotRetried() {
        let brew = FakeBrewCaskWorld(states: ["intellij-idea": .missingAppSource])

        let run = unattendedRoundWithAutoRecovery(tokens: ["intellij-idea"], brew: brew)

        #expect(run.summary.notUpgraded.map(\.name) == ["intellij-idea"])
        #expect(brew.invocations == [["upgrade", "--cask", "--", "intellij-idea"]],
                "no forced retry for a failure force cannot fix")
    }

    /// When even `--force` cannot clear the leftover, the silent cycle still collapses to a
    /// single, visible event: one retry, then a reported failure the notification counts.
    @Test("A leftover the forced retry cannot clear becomes one reported failure the notification counts")
    func unclearableLeftoverIsCountedOnce() {
        let brew = FakeBrewCaskWorld(states: ["discord": .leftoverForceCannotClear])

        let run = unattendedRoundWithAutoRecovery(tokens: ["discord"], brew: brew)
        let summary = run.summary

        #expect(summary.upgraded.isEmpty)
        #expect(brew.invocations == [
            ["upgrade", "--cask", "--", "discord"],
            ["upgrade", "--cask", "--force", "--", "discord"],
        ], "one round, one retry — not a silent per-round cycle")
        // The exact quantity the notification renders as "N nie udało się zaktualizować".
        #expect(summary.notUpgraded.count == 1)
        #expect(summary.names { $0 == .executionFailed }.count == 1)
    }

    // MARK: The background round wires the recovery (checkable where it lives)

    /// The behavioral tests above mirror the recovery decision `BackgroundUpdater` makes,
    /// because that method is wired behind live services a unit test cannot stand in for.
    /// This pins the production round to the same shape — recognize → retry with force → fold
    /// back → record — in that order, so a refactor that drops or reorders it fails here.
    @Test("The background round wires the between-phases auto-recovery path")
    func backgroundRoundWiresAutoRecovery() throws {
        let source = try backgroundUpdaterSource()

        let recognize = try #require(source.range(of: ".tokensRetryableWithForce"))
        let retry = try #require(source.range(of: "UpdatePlanner.forcedCaskCommand"))
        let foldBack = try #require(source.range(of: "BrewUpgradeOutcome.merging"))
        let record = try #require(source.range(of: "recordBackgroundRound"))

        #expect(recognize.lowerBound < retry.lowerBound,
                "the leftover must be recognized before the forced retry is built")
        #expect(retry.lowerBound < foldBack.lowerBound,
                "the forced retry must run before its outcome is folded back")
        #expect(foldBack.lowerBound < record.lowerBound,
                "the merged outcome, not the plain one, is what the round records")
    }

    /// Criterion: the notification carries the *number* of failures, so a round that only
    /// ever failed is no longer silent. Satisfied since REL-02; pinned here against regression.
    @Test("The background notification reports the number of failures")
    func backgroundNotificationReportsFailureCount() throws {
        let source = try backgroundUpdaterSource()

        #expect(source.contains("let failed = summary.names { $0 == .executionFailed"),
                "the notification derives the failed set from the whole run outcome")
        #expect(source.contains("nie udało się zaktualizować"))
        #expect(source.contains("\"\\(failed.count)\""),
                "the notification renders the *count* of failures, not just names")
    }

    // MARK: Fixtures

    private func caskItem(_ token: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: token, kind: .cask), name: token,
                     from: nil, to: nil, kind: .cask)
    }

    /// Mirrors the unattended round in `BackgroundUpdater.runIfEligible`: run the plain cask
    /// upgrade, recover a between-phases leftover with a single `--force` retry, fold the
    /// result back in, then record it through the unattended-specific aggregation.
    private func unattendedRoundWithAutoRecovery(tokens: [String], brew: FakeBrewCaskWorld) -> UpdateRunOutcome {
        var caskOutcome = brew.upgrade(UpdatePlanner.caskUpgradeCommand(tokens: tokens))
        let retryTokens = caskOutcome.tokensRetryableWithForce
        if !retryTokens.isEmpty {
            let forced = brew.upgrade(UpdatePlanner.forcedCaskCommand(tokens: retryTokens))
            caskOutcome = BrewUpgradeOutcome.merging(original: caskOutcome, forcedRetry: forced, retriedTokens: retryTokens)
        }
        var run = UpdateRunOutcome()
        run.recordBackgroundRound(tokens.map(caskItem), outcome: caskOutcome)
        return run
    }

    private func backgroundUpdaterSource(file: String = #filePath) throws -> String {
        let packageRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MacUpdater/BackgroundUpdater.swift"),
            encoding: .utf8
        )
    }

    /// A minimal stand-in for `brew upgrade --cask` reproducing the three states BG-04
    /// distinguishes: a between-phases leftover a `--force` retry clears, a leftover `--force`
    /// cannot clear, and a genuinely missing app source that must never be retried. `--force`
    /// mutates the simulated world, so a passing recovery proves the retry *causes* success
    /// rather than merely reporting it.
    private final class FakeBrewCaskWorld {
        enum State {
            case interruptedUpgradeLeftover
            case leftoverForceCannotClear
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
                            + "'/opt/homebrew/Caskroom/\(token)/1.0/\(token).app'.")
                    }
                case .leftoverForceCannotClear:
                    anyFailed = true
                    lines.append("Error: \(token): It seems there is already an App at "
                        + "'/opt/homebrew/Caskroom/\(token)/1.0/\(token).app'.")
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
}
