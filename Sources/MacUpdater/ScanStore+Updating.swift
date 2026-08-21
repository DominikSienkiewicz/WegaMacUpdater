import Foundation
import MacUpdaterCore

// MARK: - Running an update
//
// ARCH-08 — executing a planned update and reporting what it did: the package-manager calls,
// the per-item outcome, the banner, and the restart offer that follows. The rollback net around
// it is `ScanStore+Rollback`; deciding *what* to run is `ScanStore+UpdatePlan`.
extension ScanStore {
    func runUpdate(targetKeys: Set<String>) async {
        // REL-12 — a clean stop switch per run; a previous cancellation may not leak in.
        resetUpdateInterruption()
        do {
            try await dependencies.upgrades.performWriteLease(.foregroundUpgrade) { lease in
                await self.runUpdateCoordinated(targetKeys: targetKeys, operationLease: lease)
            }
        } catch is CancellationError {
            return
        } catch {
            WegaLog.error(.homebrew, "Koordynacja aktualizacji: \(error.localizedDescription)")
        }
    }

    private func runUpdateCoordinated(
        targetKeys: Set<String>,
        operationLease: OperationCoordinator.Lease
    ) async {
        guard let model, !targetKeys.isEmpty else { return }
        // F3 — never overlap with a background upgrade: both take snapshots and both call
        // `brew upgrade --cask`. The window is the one the user is waiting on.
        guard UpgradeMutex.shared.acquire() else {
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja w toku"),
                                  message: tr("Wega właśnie aktualizuje coś w tle. Spróbuj za chwilę.")))
            return
        }
        defer { UpgradeMutex.shared.release() }
        updating = true
        emitActivitySignal(.scanning)
        brewLog = []
        showLog = true
        emitWegaState(WegaState(pose: .sniff, line: tr("Aktualizuję, chwila…")))

        let plan          = UpdatePlanner.plan(selectedKeys: targetKeys)
        // The rows this run is about, captured before anything changes: the post-upgrade
        // rescan rewrites `allItems`, and an outcome has to keep pointing at the item it
        // was produced for. `name`/`key` here are what the tools and the rescan both use.
        let plannedKeys   = targetKeys
        let plannedItems  = allItems.filter { plannedKeys.contains($0.key) }
        // F2 — the exact argument vectors come from the planner, the same call the preview
        // panel renders. Building them here as well is how a dry-run starts to lie: the
        // `--force` retry path below is precisely the drift that was waiting to happen.
        let commands      = UpdatePlanner.commands(for: plan)
        let formulaArgs   = commands.first { $0.executable == "brew" && !$0.arguments.contains("--cask") }?.arguments
        let caskArgs      = commands.first { $0.executable == "brew" && $0.arguments.contains("--cask") }?.arguments
        let plannedCaskNames = plan.caskNames
        let npmNames      = plan.npmNames
        let masAppStoreIDs = plan.masAppStoreIDs
        // REL-12 — what each remaining phase would still touch, so a stop can name it.
        let boundaries    = UpgradeBoundaryKeys(planned: plannedItems, npmNames: npmNames)
        // The bar counts whole planned rows. Only the tokens this run asked brew for may be
        // credited: `brew upgrade <names…>` also upgrades outdated dependents nobody
        // selected and announces them identically. npm and the App Store advance explicitly,
        // so they are not brew tokens. A run with a single package is the one case where a
        // download can be attributed without guessing what it belongs to.
        let tracker = UpgradeProgressTracker(
            totalUnits: plannedItems.count,
            plannedTokens: Set(plan.formulaNames + plannedCaskNames),
            soleDownloadToken: plannedItems.count == 1 ? plannedItems.first?.name : nil
        )
        upgradeTracker = tracker
        upgradeProgress = tracker.progress
        // Every later exit — the stop switch, a publisher veto, a thrown error — must leave
        // the bar gone, so clearing is a defer rather than a line each return remembers.
        defer {
            upgradeProgress = nil
            upgradeTracker = nil
        }
        // REL-12 — zeroth boundary: stopping here also skips the snapshot/preflight work.
        guard !shouldStopUpdate(before: Array(plannedKeys)) else {
            updating = false
            report(run: UpdateRunOutcome())
            return
        }

        let caskPreparation: ForegroundCaskPreparation?
        if plannedCaskNames.isEmpty {
            caskPreparation = nil
        } else {
            switch await prepareForegroundCasks(plannedCaskNames, targetKeys: targetKeys) {
            case .ready(let prepared):
                caskPreparation = prepared
            case .blocked(let publisherVetoes):
                var blockedRun = UpdateRunOutcome()
                blockedRun.recordPublisherVetoes(
                    plannedItems.filter { $0.kind == .cask },
                    audits: publisherVetoes
                )
                if !blockedRun.summary.isEmpty { report(run: blockedRun) }
                updating = false
                return
            }
        }

        // REL-15 — pre-capture which casks being updated own an app running right now.
        // Detection is generic: each cask's resolved bundle URL is matched against the live
        // applications, so it covers the whole catalog, not 16 hardcoded tokens. The restart
        // map is passed only as an override for casks whose process name is atypical.
        let candidates = RunningCaskDetector.runningApps(
            tokens: plannedCaskNames,
            appPaths: caskPreparation?.appPaths ?? [:],
            running: runningApplicationInspector.runningApplications(),
            overrides: MacUpdaterConstants.restartMap
        )

        // REL-02 — one outcome per item and source, filled in phase by phase (execution →
        // validation → rollback → rescan). Nothing announces success before every phase
        // that applies to an item has had its say.
        var run = UpdateRunOutcome()

        // Brew upgrade — formulae. One call for all of them, because they share
        // dependencies: a process each would rebuild the same dependency several times over
        // and the run would get slower, not faster. It is also the only call that streams
        // into the progress tracker — see `creditUnit()` for why nothing else may.
        if let formulaArgs {
            let outcome = await runBrewUpgrade(arguments: formulaArgs, logSource: "brew", streamsProgress: true)
            run.record(plannedItems.filter { $0.kind == .formula }, outcome: outcome)
        }

        // REL-12 — boundary: a stop asked for mid-formulae lands here, before bundles move.
        let stopBeforeCasks = shouldStopUpdate(before: boundaries.afterFormulae)

        // Brew upgrade — casks (FEAT-05 snapshot przed, canary/rollback + FEAT-04 ledger po)
        if !stopBeforeCasks, caskArgs != nil, let caskPreparation {
            // REL-03 — resolved here, now, not left to whatever a full scan happened to put
            // in the map: after `restoreLastScan()` it is empty, and an empty map means no
            // snapshot to roll back to and no bundle for the canary to inspect. Both phases
            // are handed this one value, so neither can be given a different answer.
            let appPaths = caskPreparation.appPaths
            let snapshots = caskPreparation.snapshots
            run.recordPublisherVetoes(
                plannedItems.filter { $0.kind == .cask },
                audits: caskPreparation.publisherVetoes
            )
            let caskNames = caskPreparation.trustedCaskNames
            if !caskNames.isEmpty {
                // LT-01 — the last line before the mutation: a crash after it reads as
                // "disk state unknown, probe me", a crash before it reads as "never ran".
                caskPreparation.operation.recordInstalling()
                // One brew process per cask. The canary/rollback verdict is a phase of the
                // same result rather than an aside — it used to be raised after the summary
                // had already been computed, so a cask the guard had just rolled back still
                // counted towards "Zaktualizowano N pakietów" — and it now settles per cask,
                // as soon as that cask's own process is done.
                for token in caskNames {
                    guard let item = plannedItems.first(where: { $0.kind == .cask && $0.name == token }) else { continue }
                    let result = await upgradeOneCask(
                        item: item,
                        appPaths: appPaths,
                        snapshots: snapshots,
                        operation: caskPreparation.operation
                    )
                    fold(result, into: &run)
                }
            } else {
                // Every candidate was vetoed by the publisher watchdog: no snapshot exists
                // and brew never ran — nothing to retain.
                caskPreparation.operation.abortUnfinished()
                UpdateOperationStore.shared.removeOperation(id: caskPreparation.operation.operation.id)
            }
        } else if let caskPreparation {
            // REL-12 stopped the run before the cask phase (or the plan held no cask
            // command): brew never ran, the clones restore nothing — settle the journal
            // and drop the operation instead of leaving an orphan for recovery to find.
            caskPreparation.operation.abortUnfinished()
            UpdateOperationStore.shared.removeOperation(id: caskPreparation.operation.operation.id)
        }

        // npm upgrades one package per process, so every iteration is a REL-12 stop boundary.
        for (index, pkg) in npmNames.enumerated() {
            if shouldStopUpdate(before: boundaries.fromNpmPackage(at: index)) { break }
            guard let item = plannedItems.first(where: { $0.kind == .npm && $0.name == pkg }) else { continue }
            fold(await upgradeOneNpmPackage(item: item), into: &run)
        }

        // MAS upgrade — the IDs are load-bearing. A bare `mas upgrade` expands to every
        // outdated App Store app, including rows outside the visible/confirmed UX-01 set.
        // mas still reports no per-app result, so one failure becomes a synthetic outcome
        // per planned item, exactly as `runNpmUpgrade` does.
        if !masAppStoreIDs.isEmpty, !shouldStopUpdate(before: boundaries.masKeys) {
            let appStoreItems = plannedItems.filter { $0.kind == .appStore }
            // One opaque call for the whole batch: the bar takes over the label but names
            // no app, because mas reports none.
            tracker.beginInstallingBatch()
            upgradeProgress = tracker.progress
            brewLog.append(UpgradeLogPrefix.line(
                "$ mas upgrade " + masAppStoreIDs.joined(separator: " "), from: "mas"))
            var masFailure: String?
            do {
                let result = try await model.masService.upgrade(appStoreIDs: masAppStoreIDs)
                let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
                brewLog.append(contentsOf: UpgradeLogPrefix.lines(lines, from: "mas"))
            } catch {
                masFailure = error.localizedDescription
                brewLog.append(UpgradeLogPrefix.line("error: \(error.localizedDescription)", from: "mas"))
                WegaLog.error(.app, "mas upgrade: \(error.localizedDescription)")
            }
            run.record(masItems: appStoreItems, failure: masFailure)
            // mas reports nothing per app, so the whole batch advances at once — and only
            // when it succeeded, because a failure is no evidence any single app updated.
            if masFailure == nil {
                tracker.completeUnits(appStoreItems.count)
                upgradeProgress = tracker.progress
            }
        }

        // REL-04 — no `brew cleanup` here. It ran after *every* update, including one that
        // touched only npm or the App Store and one that had just failed, and it appeared in
        // no preview: the plan panel renders `UpdatePlanner.commands(for:)`, which is the
        // whole set of commands this method may execute. It is also the worst possible
        // moment for it — clearing Homebrew's cache of previous versions removes what a
        // recovery from a bad upgrade would reinstall from.
        selected.removeAll()
        restartCandidates = candidates

        // Re-query brew/mas so the list reflects reality, not optimistic clearing.
        // If a cask failed (e.g. "App source not there"), it will still appear here.
        // Suppress its icon signal — the upgrade outcome below sets the final state.
        // M2(d) — lightweight: no second `brew update`, no second stale-cask sweep. The
        // rescan is not a stage of this bar: `runCheck` replaces the results view with the
        // scan's own screen, so the two bars hand over to each other.
        await runCheck(emitActivity: false, lightweight: true, operationLease: operationLease)

        updating = false

        // The rescan is the last phase an item has to clear: whatever the tool claimed, an
        // item the fresh list still reports was not updated, and a rescan that could not
        // answer leaves the upgrade unconfirmed rather than confirmed-good.
        run.applyRescan(stillOutdatedKeys: Set(allItems.map(\.key)),
                        confirmed: Set(plannedItems.map(\.kind)).isSubset(of: confirmedSourceKinds))

        report(run: run)
        // LT-01 — the run's committed snapshots are the undo section's content.
        refreshUndoableUpdates()
    }

    /// Turns the run into what the user sees: the sticky alerts first (a failed rollback and
    /// a changed publisher are the two things that must not be missable), then the summary
    /// banner — green only when every item cleared every phase.
    private func report(run: UpdateRunOutcome) {
        let summary = run.summary

        // OBS-02 — the verdicts below drive banners that vanish with the window. The same
        // run is also written to the durable journal, so a bug report filed tomorrow can
        // still say what happened today.
        dependencies.recordUpdateRun(
            UpdateJournalEntry(summary: summary, trigger: .manual, finishedAt: Date())
        )

        for outcome in summary.rollbackFailures {
            showStickyBanner(BannerData(variant: .danger,
                                        title: tr("Rollback się nie powiódł"),
                                        message: trf("%@: nowa wersja nie przeszła kontroli, a przywrócenie poprzedniej nie powiodło się. Sprawdź aplikację przed użyciem.", "\(outcome.name)"),
                                        action: .openLogs))
        }
        for outcome in summary.publisherChanges {
            let old: String
            let new: String?
            let message: String
            switch outcome.verdict {
            case .publisherChanged(let previous, let current):
                old = previous
                new = current
                message = trf("%@: Team ID zmienił się (%@ → %@). Zweryfikuj.",
                              "\(outcome.name)", "\(old)", "\(new ?? "—")")
            case .publisherChangedAndRolledBack(let previous, let current):
                old = previous
                new = current
                message = trf("%@: Team ID zmienił się (%@ → %@). Przywrócono poprzednią zaufaną wersję.",
                              "\(outcome.name)", "\(old)", "\(new ?? "—")")
            case .publisherMismatchBeforeUpgrade(let previous, let current):
                old = previous
                new = current
                message = trf("%@: Team ID już różnił się od zaufanego baseline (%@ → %@). Aktualizację zablokowano przed uruchomieniem.",
                              "\(outcome.name)", "\(old)", "\(new ?? "—")")
            default:
                continue
            }
            showStickyBanner(BannerData(variant: .danger, title: tr("Zmiana wydawcy"),
                                        message: message))
        }

        // REL-05 — the permission is Wega's, not this run's, so the gate is settled from what
        // this run observed, before any branch can return. The unattended round already does
        // exactly this; the window only ever armed it. A user who met the refusal here, granted
        // the permission and then ran a clean update from this same window left unattended
        // rounds blocked for the full 24 h with nothing left to block them — and nothing on
        // screen to say why, because the consequence lands in the path they are not watching.
        //
        // Keyed on the refusal rather than on success, like `BackgroundUpdater`: a run that
        // failed for some unrelated reason still proves the permission is no longer missing.
        if let settleAppManagementPermission = dependencies.settleAppManagementPermission {
            settleAppManagementPermission(summary.needsAppManagementPermission)
        } else if summary.needsAppManagementPermission {
            AppManagementDenialStore.shared.recordDenial()
        } else {
            AppManagementDenialStore.shared.clear()
        }

        // REL-12 — a run the user stopped is never announced as a finished one.
        let interrupted = updateInterruption.didSkipWork
        if interrupted { reportInterruptedRun(upgraded: summary.upgraded.count) }
        if summary.allItemsUpgraded {
            guard !interrupted else { return }
            let count = summary.upgraded.count
            showBanner(BannerData(variant: .success,
                                  title: trf("Zaktualizowano %@ pakietów", "\(count)"),
                                  message: tr("Wszystko gotowe.")))
            emitActivitySignal(.success)
            emitWegaState(WegaState(pose: .happy, line: trf("Gotowe! %@ pakietów odświeżonych.", "\(count)")))
            WegaLog.info(.homebrew, "Zaktualizowano \(count) pakietów")
            return
        }

        let failedNames = summary.notUpgraded.map(\.name)
        let baseDetail = failedNames.isEmpty
            ? tr("Brew zgłosił błąd — sprawdź log poniżej.")
            : trf("Nie udało się: %@. Szczegóły w logu.", "\(failedNames.joined(separator: ", "))")
        // REL-05 — a missing "App Management" grant outranks the sudo hint: it explains the
        // whole failure, and its `stderr` ("ditto: …: Operation not permitted") is exactly the
        // line a user cannot act on. One named permission, one button that grants it.
        if summary.needsAppManagementPermission {
            showBanner(BannerData(
                variant: .danger,
                title: tr("Brak uprawnienia „Zarządzanie aplikacjami”"),
                message: trf("%@ macOS nie pozwolił Wedze podmienić aplikacji w /Applications. Przyznaj uprawnienie „Zarządzanie aplikacjami” w Ustawieniach systemowych → Prywatność i bezpieczeństwo.", "\(baseDetail)"),
                action: .openAppManagementSettings
            ))
        } else {
            let detail = summary.needsSudoPassword
                ? trf("%@ Cask wymaga hasła administratora. Włącz Touch ID, żeby autoryzować aktualizacje odciskiem — bez wpisywania hasła.", "\(baseDetail)")
                : baseDetail
            showBanner(BannerData(variant: .danger,
                                  title: tr("Aktualizacja niekompletna"),
                                  message: detail,
                                  action: summary.needsSudoPassword ? .openSettings : nil))
        }
        emitActivitySignal(.error)
        emitWegaState(WegaState(pose: .alert, line: tr("Część pakietów się nie zaktualizowała.")))
        // Surface *why* each upgrade failed — the brew error block, not just the token
        // name — so the log explains the failure instead of only flagging it. The block
        // rides on the failure entry as one detail rather than as N loose lines, so
        // selecting that entry for a bug report carries the explanation with it.
        WegaLog.error(
            .homebrew,
            "Aktualizacja niekompletna: \(failedNames.isEmpty ? "Brew zgłosił błąd" : failedNames.joined(separator: ", "))",
            detail: LogDetail(
                stderr: summary.diagnostics.joined(separator: "\n"),
                source: "cask"
            )
        )
        for outcome in summary.notUpgraded {
            WegaLog.error(.homebrew, "\(outcome.name): \(outcome.verdict.logDescription)")
        }
    }

    /// Folds one row's lane result into the run.
    ///
    /// A result with no outcome is a row the stop switch caught before it started: it is
    /// already recorded as skipped by `shouldStopUpdate`, and adding a verdict for it here
    /// would report on a row nothing ever attempted.
    func fold(_ result: LaneItemResult, into run: inout UpdateRunOutcome) {
        guard let outcome = result.outcome else { return }
        run.record([result.item], outcome: outcome)
        if let validation = result.validation {
            run.applyValidation([result.item.name: validation])
        }
    }

    func restartApp(_ info: RestartInfo) async {
        restartBusy = info.processName
        await processes.kill(info.processName)
        try? await Task.sleep(for: .milliseconds(800))
        await processes.launch(appName: info.appName)
        restartCandidates.removeAll { $0.processName == info.processName }
        restartBusy = nil
    }
}
