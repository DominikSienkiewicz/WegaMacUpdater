import Foundation
import MacUpdaterCore

// MARK: - One planned row at a time
//
// ARCH-08 — the per-row half of an update run: the package-manager process for a single
// selected item, the two retries that apply to it, its progress unit and its log prefix.
// Deciding *what* to run is `ScanStore+UpdatePlan`; sequencing the lanes and reporting the
// run is `ScanStore+Updating`; the snapshot/canary net around a cask is `ScanStore+Rollback`.
extension ScanStore {

    /// What one lane produced for one planned row.
    ///
    /// A lane never touches the run's `UpdateRunOutcome`. It hands back what it produced and
    /// the orchestrator folds every lane's answer in once, in the plan's order — so the
    /// report never depends on which process happened to finish first.
    struct LaneItemResult: Sendable {
        let item: OutdatedItem
        /// `nil` when the run stopped before this row started. Never attempted is not the
        /// same as attempted and failed, and only one of the two may be reported.
        let outcome: BrewUpgradeOutcome?
        let validation: CaskValidationVerdict?

        init(item: OutdatedItem, outcome: BrewUpgradeOutcome?, validation: CaskValidationVerdict? = nil) {
            self.item = item
            self.outcome = outcome
            self.validation = validation
        }
    }

    // MARK: Progress accounting

    /// A row's process is starting.
    ///
    /// The bar may name the package only while it is the only one running: with several
    /// processes in flight, naming one of them misdescribes the other two, so the run falls
    /// back to the unnamed batch label the App Store phase already uses.
    func beginItem(named token: String) {
        inFlightItemCount += 1
        if inFlightItemCount > 1 {
            upgradeTracker?.beginInstallingBatch()
        } else {
            upgradeTracker?.beginInstalling(token: token)
        }
        upgradeProgress = upgradeTracker?.progress
    }

    func endItem() {
        inFlightItemCount = max(0, inFlightItemCount - 1)
    }

    /// One planned row finished successfully.
    ///
    /// Per-row lanes never feed the tracker's stream parser: it keeps a single line buffer
    /// and a single in-flight token, so several concurrent streams would corrupt both. They
    /// advance it explicitly instead — exactly as the npm loop always has.
    func creditUnit() {
        upgradeTracker?.completeUnits(1)
        upgradeProgress = upgradeTracker?.progress
    }

    // MARK: One cask

    /// Upgrades exactly one cask and returns its outcome together with the canary/rollback
    /// verdict for the same token.
    ///
    /// The verdict is produced here rather than in a phase after the whole run, so a build
    /// that fails the canary is restored while the other rows are still working.
    func upgradeOneCask(
        item: OutdatedItem,
        appPaths: [String: URL],
        snapshots: [String: URL],
        operation: UpdateOperationSession
    ) async -> LaneItemResult {
        let token = item.name
        beginItem(named: token)
        defer { endItem() }

        var outcome = await runBrewUpgrade(
            arguments: UpdatePlanner.caskUpgradeCommand(tokens: [token]).arguments,
            logSource: token,
            streamsProgress: false
        )

        // Two brew processes can collide on a lock they both need. Nothing was installed
        // when that happens — which is what makes one retry safe, and is the whole running
        // cost of upgrading casks concurrently.
        if outcome.isHomebrewLockCollision {
            brewLog.append(UpgradeLogPrefix.line(
                "↻ " + trf("Homebrew był zajęty (%@) — ponawiam.", "\(token)"), from: token))
            WegaLog.info(.homebrew, "Kolizja blokad Homebrew — ponawiam \(token)")
            try? await Task.sleep(for: .seconds(2))
            outcome = await runBrewUpgrade(
                arguments: UpdatePlanner.caskUpgradeCommand(tokens: [token]).arguments,
                logSource: token,
                streamsProgress: false
            )
        }

        // Auto-recover an interrupted upgrade: brew bails because a stale staged app from a
        // previous, cut-short run occupies the destination. `--force` overwrites it.
        if outcome.tokensRetryableWithForce.contains(token) {
            brewLog.append(UpgradeLogPrefix.line(
                "↻ " + trf("Przerwana aktualizacja (%@) — ponawiam z --force.", "\(token)"), from: token))
            WegaLog.info(.homebrew, "Przerwana aktualizacja casku — ponawiam z --force: \(token)")
            let retry = await runBrewUpgrade(
                arguments: UpdatePlanner.forcedCaskCommand(tokens: [token]).arguments,
                logSource: token,
                streamsProgress: false
            )
            outcome = BrewUpgradeOutcome.merging(original: outcome, forcedRetry: retry, retriedTokens: [token])
        }

        let verdicts = await postCaskUpgrade(
            [token], appPaths: appPaths, snapshots: snapshots, operation: operation
        )
        if outcome.isSuccessful { creditUnit() }
        return LaneItemResult(item: item, outcome: outcome, validation: verdicts[token])
    }

    // MARK: One npm package

    func upgradeOneNpmPackage(item: OutdatedItem) async -> LaneItemResult {
        let name = item.name
        beginItem(named: name)
        defer { endItem() }

        let outcome = await runNpmUpgrade(name: name)
        if outcome.isSuccessful { creditUnit() }
        return LaneItemResult(item: item, outcome: outcome)
    }

    // MARK: The processes

    /// Runs `brew <arguments>` streaming output into the log, and returns an outcome that
    /// reflects whether brew *actually* succeeded — exit code 0 alone is unreliable for cask
    /// upgrades.
    ///
    /// `streamsProgress` is true only for the single formula call. The tracker parses one
    /// stream with one line buffer, so nothing else may feed it: see `creditUnit()`.
    func runBrewUpgrade(
        arguments: [String],
        logSource: String,
        streamsProgress: Bool
    ) async -> BrewUpgradeOutcome {
        guard let model else { return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: []) }
        brewLog.append(UpgradeLogPrefix.line("$ brew \(arguments.joined(separator: " "))", from: logSource))
        var captured = ""
        var exitCode: Int32 = 0
        do {
            let stream = try model.brewService.events(arguments: arguments)
            exitCode = try await ProcessEventStream.drain(stream) { chunk in
                captured += chunk
                brewLog = ProcessEventStream.appendingCapped(
                    UpgradeLogPrefix.lines(ProcessEventStream.lines(from: chunk), from: logSource),
                    to: brewLog
                )
                if streamsProgress { upgradeProgress = upgradeTracker?.consume(chunk: chunk) }
            }
        } catch {
            brewLog.append(UpgradeLogPrefix.line("error: \(error.localizedDescription)", from: logSource))
            if streamsProgress {
                upgradeTracker?.brewCallFinished(succeeded: false)
                upgradeProgress = upgradeTracker?.progress
            }
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: [error.localizedDescription])
        }
        let outcome = BrewUpgradeOutcome.analyze(exitCode: exitCode, output: captured)
        if streamsProgress {
            upgradeTracker?.brewCallFinished(succeeded: outcome.isSuccessful)
            upgradeProgress = upgradeTracker?.progress
        }
        return outcome
    }

    /// The log line names the command `UpdatePlanner` emits for this package, not one built
    /// here: `npmService.upgradeEvents(name:)` owns the real argument vector, and a second
    /// hand-written spelling in the log is how a preview starts to disagree with the run.
    func runNpmUpgrade(name: String) async -> BrewUpgradeOutcome {
        guard let model else { return BrewUpgradeOutcome(exitCode: -1, failedTokens: [name], errorLines: []) }
        brewLog.append(UpgradeLogPrefix.line("$ npm install -g -- \(name)@latest", from: name))
        var exitCode: Int32 = 0
        do {
            let stream = try await model.npmService.upgradeEvents(name: name)
            exitCode = try await ProcessEventStream.drain(stream) { chunk in
                brewLog = ProcessEventStream.appendingCapped(
                    UpgradeLogPrefix.lines(ProcessEventStream.lines(from: chunk), from: name),
                    to: brewLog
                )
            }
        } catch {
            brewLog.append(UpgradeLogPrefix.line("error: \(error.localizedDescription)", from: name))
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [name], errorLines: [error.localizedDescription])
        }
        return BrewUpgradeOutcome(exitCode: exitCode, failedTokens: exitCode == 0 ? [] : [name], errorLines: [])
    }
}
