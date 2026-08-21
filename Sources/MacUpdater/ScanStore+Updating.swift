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
        guard model != nil, !targetKeys.isEmpty else { return }
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

        // FEAT-04 — a publisher veto is about a cask that will never be attempted, so it is
        // recorded before any lane starts rather than alongside what the lanes produce.
        if let caskPreparation {
            run.recordPublisherVetoes(
                plannedItems.filter { $0.kind == .cask },
                audits: caskPreparation.publisherVetoes
            )
        }
        // The cask lane runs only when the plan actually emitted a cask command *and* the
        // preparation left a trusted token to run it on.
        let caskLanePreparation = caskArgs != nil && caskPreparation?.trustedCaskNames.isEmpty == false
            ? caskPreparation
            : nil

        // The four lanes overlap. They drive four different tools over four different sets
        // of paths, so nothing one of them touches is anything another one can reach — and
        // the wall-clock of a mixed selection stops being the sum of its parts. The rescan
        // below is what waits for all of them.
        //
        // Closures rather than `async let`: the cask lane needs the run's
        // `UpdateOperationSession`, a reference type that is rightly not `Sendable`. Passing
        // it as an argument would send it across a task boundary; capturing it in a
        // `@MainActor` closure keeps it on the one actor it never leaves.
        let lanes: [@MainActor @Sendable () async -> UpgradeLaneOutput] = [
            { .rows(await self.runFormulaLane(items: plannedItems, arguments: formulaArgs)) },
            { .rows(await self.runCaskLane(items: plannedItems, preparation: caskLanePreparation)) },
            { .rows(await self.runNpmLane(items: plannedItems, names: npmNames)) },
            {
                let mas = await self.runMasLane(items: plannedItems, appStoreIDs: masAppStoreIDs)
                return .appStore(items: mas.items, failure: mas.failure)
            }
        ]
        // `limit: 0` — no cap here. These are four different tools, not four processes
        // competing for one; the caps that matter are the ones inside the cask and npm lanes.
        let laneOutputs = await runBoundedOnMainActor(limit: 0, lanes)

        // Folded in the plan's order, never the order the lanes happened to finish in: a
        // report that reshuffled itself run to run would be unreadable, and the log carries
        // the real chronology already.
        let laneRows = laneOutputs.flatMap { output -> [LaneItemResult] in
            if case .rows(let rows) = output { return rows }
            return []
        }
        let byKey = Dictionary(laneRows.map { ($0.item.key, $0) }, uniquingKeysWith: { first, _ in first })
        for item in plannedItems {
            guard let result = byKey[item.key] else { continue }
            fold(result, into: &run)
        }
        for case .appStore(let items, let failure) in laneOutputs where !items.isEmpty {
            run.record(masItems: items, failure: failure)
        }

        let casks = laneRows.filter { $0.item.kind == .cask }

        // LT-01 / REL-12 — an operation none of whose casks ever ran: every candidate was
        // vetoed by the publisher watchdog, or a stop caught them all while they were still
        // queued. Either way brew never ran and the clones restore nothing, so settle the
        // journal and drop the operation instead of leaving recovery an orphan that claims a
        // mutation was under way.
        if let caskPreparation, casks.allSatisfy({ $0.outcome == nil }) {
            caskPreparation.operation.abortUnfinished()
            UpdateOperationStore.shared.removeOperation(id: caskPreparation.operation.operation.id)
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
