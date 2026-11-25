import Foundation
import MacUpdaterCore

// MARK: - Running an update
//
// ARCH-08 — executing a planned update and reporting what it did: the package-manager calls,
// the per-item outcome, the run's report, and the restart offer that follows. The rollback net
// around it is `ScanStore+Rollback`; deciding *what* to run is `ScanStore+UpdatePlan`.
extension ScanStore {
    func runUpdate(targetKeys: Set<String>, approvedReplacements: [QueuedCaskReplacement] = []) async {
        let targetKeys = ServiceVendorUpdatePolicy.eligibleKeys(DockerDesktopUpdatePolicy.eligibleKeys(targetKeys))
        let replacements = approvedReplacements.filter { targetKeys.contains($0.key) }
        guard !targetKeys.isEmpty else { return }
        let inherited = UpdateDiagnostics.current
        let trace = inherited ?? DiagnosticRun(trigger: "foreground", subjects: targetKeys.sorted())
        defer { if inherited == nil { trace.finish() } }
        await UpdateDiagnostics.$current.withValue(trace) {
            await runUpdateTraced(targetKeys: targetKeys, replacements: replacements)
        }
    }

    private func runUpdateTraced(targetKeys: Set<String>, replacements: [QueuedCaskReplacement]) async {
        do {
            try await dependencies.upgrades.performWriteLease(.foregroundUpgrade) { lease in
                await self.runUpdateCoordinated(targetKeys: targetKeys, replacements: replacements, operationLease: lease)
            }
        } catch is CancellationError {
            UpdateDiagnostics.record("update.cancelled", fields: ["stage": "writeLease"])
            return
        } catch {
            WegaLog.error(.homebrew, "Koordynacja aktualizacji: \(error.localizedDescription)")
        }
    }

    private func runUpdateCoordinated(
        targetKeys: Set<String>,
        replacements: [QueuedCaskReplacement],
        operationLease: OperationCoordinator.Lease
    ) async {
        let packageItems = allItems.filter { targetKeys.contains($0.key) }
        let plannedItems = packageItems + replacements.map(\.item)
        guard model != nil, !plannedItems.isEmpty else {
            UpdateDiagnostics.record("update.skipped", fields: ["reason": model == nil ? "modelUnavailable" : "emptySelection"])
            return
        }
        // F3 — never overlap with a background upgrade: both take snapshots and both call
        // `brew upgrade --cask`. The window is the one the user is waiting on.
        guard dependencies.upgradeMutex.acquire() else {
            UpdateDiagnostics.record("update.skipped", fields: ["reason": "upgradeMutexBusy"])
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja w toku"),
                                  message: tr("Wega właśnie aktualizuje coś w tle. Spróbuj za chwilę."), action: .openLogs))
            return
        }
        defer { dependencies.upgradeMutex.release() }
        resetUpdateInterruption()
        // C2 stage 4 — the next run closes the previous run's summary, once it holds the lock.
        closeRunReport()
        updating = true
        emitActivitySignal(.updating)
        brewLog = []
        showLog = true
        // C2 — Wega stands still for a run; she sniffs only while a scan runs.
        emitWegaState(WegaState(pose: .idle, line: tr("Aktualizuję, chwila…")))

        let plan          = UpdatePlanner.plan(selectedKeys: Set(packageItems.map(\.key)))
        // The rows this run is about, captured before anything changes: the post-upgrade
        // rescan rewrites `allItems`, and an outcome has to keep pointing at the item it
        // was produced for. `name`/`key` here are what the tools and the rescan both use.
        let plannedKeys   = plannedItems.map(\.key)
        for item in plannedItems {
            UpdateDiagnostics.record("update.plannedItem", fields: [
                "key": item.key, "token": item.name, "kind": String(describing: item.kind),
                "previousVersion": item.from ?? "unknown", "targetVersion": item.to ?? "unknown"
            ])
        }
        // F2 — the exact argument vectors come from the planner, the same call the preview
        // panel renders. Building them here as well is how a dry-run starts to lie: the
        // `--force` retry path below is precisely the drift that was waiting to happen.
        let commands      = UpdatePlanner.commands(for: plan)
        let formulaArgs   = commands.first { $0.executable == "brew" && !$0.arguments.contains("--cask") }?.arguments
        let caskArgs      = commands.first { $0.executable == "brew" && $0.arguments.contains("--cask") }?.arguments
        let plannedCaskNames = plan.caskNames
        let npmNames      = plan.npmNames
        let masAppStoreIDs = plan.masAppStoreIDs
        // The run's counter counts whole planned rows. Only the tokens this run asked brew for may be
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
        // Every later exit — the stop switch, a publisher veto, a thrown error — must take
        // the progress out of the band, so clearing is a defer rather than a line each return
        // remembers.
        defer {
            upgradeProgress = nil
            upgradeTracker = nil
        }
        // C2 stage 3 — the board leaves on every exit for the same reason, through its own defer.
        beginRunBoard(planned: plannedItems)
        defer { endRunBoard() }
        // Held casks take no part in the preparation: their download, disk margin or snapshot
        // must not block the updates that need no password.
        let heldCaskNames = beginPasswordHold(plannedCaskNames: plannedCaskNames, planned: packageItems)
        let runnableCaskNames = plannedCaskNames.filter { !heldCaskNames.contains($0) }
        // REL-12 — zeroth boundary: stopping here also skips the snapshot/preflight work.
        guard !shouldStopUpdate(before: plannedKeys) else {
            updating = false
            report(run: UpdateRunOutcome(), planned: plannedItems)
            return
        }

        let caskPreparation: ForegroundCaskPreparation?
        if runnableCaskNames.isEmpty {
            caskPreparation = nil
        } else {
            switch await prepareForegroundCasks(runnableCaskNames, targetKeys: targetKeys.subtracting(heldForPasswordKeys)) {
            case .ready(let prepared):
                caskPreparation = prepared
                UpdateStageDiagnostics.recordOperation(prepared.operation)
            case .blocked(let publisherVetoes):
                UpdateDiagnostics.record("update.deferred", fields: [
                    "reason": "caskPreparationBlocked", "publisherVetoes": publisherVetoes.keys.sorted().joined(separator: ",")
                ])
                var blockedRun = UpdateRunOutcome()
                blockedRun.recordPublisherVetoes(
                    packageItems.filter { $0.kind == .cask },
                    audits: publisherVetoes
                )
                if !blockedRun.summary.isEmpty { report(run: blockedRun, planned: plannedItems) }
                updating = false
                return
            }
        }

        // REL-15 — pre-capture which casks being updated own an app running right now.
        // Detection is generic: each cask's resolved bundle URL is matched against the live
        // applications, so it covers the whole catalog, not 16 hardcoded tokens. The restart
        // map is passed only as an override for casks whose process name is atypical.
        let runningApplications = runningApplicationInspector.runningApplications()
        let candidates = RunningCaskDetector.runningApps(
            tokens: runnableCaskNames,
            appPaths: caskPreparation?.appPaths ?? [:],
            running: runningApplications,
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
                packageItems.filter { $0.kind == .cask },
                audits: caskPreparation.publisherVetoes
            )
        }
        // The cask lane runs only when the plan actually emitted a cask command *and* the
        // preparation left a trusted token to run it on.
        let caskLanePreparation = caskArgs != nil && caskPreparation?.trustedCaskNames.isEmpty == false
            ? caskPreparation
            : nil
        markCasksThatWillNotRun(packageItems, trusted: caskLanePreparation?.trustedCaskNames ?? [])

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
            { .rows(await self.runFormulaLane(items: packageItems, arguments: formulaArgs)) },
            { .rows(await self.runCaskLane(items: packageItems, preparation: caskLanePreparation)) },
            { .rows(await self.runNpmLane(items: packageItems, names: npmNames)) },
            {
                let mas = await self.runMasLane(items: packageItems, appStoreIDs: masAppStoreIDs)
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
        let replacementRows = await runQueuedCaskReplacements(replacements)
        let byKey = Dictionary((laneRows + replacementRows).map { ($0.item.key, $0) }, uniquingKeysWith: { first, _ in first })
        for item in plannedItems {
            guard let result = byKey[item.key] else { continue }
            fold(result, into: &run)
        }
        for case .appStore(let items, let failure) in laneOutputs where !items.isEmpty {
            run.record(masItems: items, failure: failure)
        }

        // LT-01 / REL-12 — an operation none of whose casks ever ran: every candidate was
        // vetoed by the publisher watchdog, or a stop caught them all while they were still
        // queued. Either way brew never ran and the clones restore nothing, so settle the
        // journal and drop the operation instead of leaving recovery an orphan that claims a
        // mutation was under way.
        let noCaskRan = laneRows.allSatisfy { $0.item.kind != .cask || $0.outcome == nil }
        if let caskPreparation, noCaskRan {
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
        restartDockerBundleURLs = dockerRestartBundles(
            tokens: runnableCaskNames, appPaths: caskPreparation?.appPaths ?? [:], running: runningApplications
        )
        restartDiagnosticOperationIDs.removeAll()
        if let operationID = caskPreparation?.operation.operation.id {
            for candidate in candidates { restartDiagnosticOperationIDs[candidate.processName] = operationID }
        }

        // Re-query brew/mas so the list reflects reality, not optimistic clearing.
        // If a cask failed (e.g. "App source not there"), it will still appear here.
        // Suppress its icon signal — the upgrade outcome below sets the final state.
        // M2(d) — lightweight: no second `brew update`, no second stale-cask sweep. C2 stage 4 —
        // quiet: the check runs in place under the run, so the band, the locked list and the log
        // stay on screen, and the band reads `updating && isRefreshing` as "Sprawdzam wynik".
        UpdateDiagnostics.record("rescan.started", fields: ["lightweight": "true"])
        await runCheck(emitActivity: false, lightweight: true, quiet: true, operationLease: operationLease)
        UpdateDiagnostics.record("rescan.result", fields: [
            "confirmed": String(Set(plannedItems.map(\.kind)).isSubset(of: confirmedSourceKinds)),
            "stillOutdatedKeys": allItems.map(\.key).sorted().joined(separator: ",")
        ])

        updating = false
        countCompletedRun()

        // The rescan is the last phase an item has to clear: whatever the tool claimed, an
        // item the fresh list still reports was not updated, and a rescan that could not
        // answer leaves the upgrade unconfirmed rather than confirmed-good.
        let unchangedReplacements = replacements.filter { !$0.reachedApprovedVersion }.map(\.key)
        let outdated = stillOutdatedKeys.union(unchangedReplacements)
        run.applyRescan(stillOutdatedKeys: outdated,
                        confirmed: Set(plannedItems.map(\.kind)).isSubset(of: confirmedSourceKinds))

        let replacementPaths = Dictionary(replacements.map { ($0.token, $0.app.path) }, uniquingKeysWith: { first, _ in first })
        let replacementOperations = Dictionary(replacementRows.compactMap { row in
            row.operationID.map { (row.item.key, $0) }
        }, uniquingKeysWith: { first, _ in first })
        offerQueuedReplacementRestarts(
            run.summary, paths: replacementPaths, operations: replacementOperations, running: runningApplications
        )
        report(run: run, planned: plannedItems,
               caskOperationID: caskPreparation?.operation.operation.id,
               caskAppPaths: (caskPreparation?.appPaths ?? [:]).merging(replacementPaths) { first, _ in first },
               replacementOperations: replacementOperations)
        // LT-01 — the run's committed snapshots are the undo section's content.
        refreshUndoableUpdates()
    }

    private func offerQueuedReplacementRestarts(
        _ summary: UpdateRunSummary, paths: [String: URL],
        operations: [String: UUID], running: [RunningApplicationTarget]
    ) {
        for outcome in summary.upgraded {
            guard let operationID = operations[outcome.key],
                  let candidate = RunningCaskDetector.runningApps(
                    tokens: [outcome.name], appPaths: paths, running: running, overrides: MacUpdaterConstants.restartMap
                  ).first, !restartCandidates.contains(candidate) else { continue }
            restartCandidates.append(candidate)
            restartDiagnosticOperationIDs[candidate.processName] = operationID
        }
    }

    private var stillOutdatedKeys: Set<String> {
        Set(allItems.map(\.key) + visibleManual.map(QueuedCaskReplacement.key(for:)))
    }

    /// Turns the run into what the user sees: the report the after-update summary shows (C2
    /// stage 4), the sticky alert a failed rollback earns (it must not be missable, so it is a
    /// row and a banner), and the banners whose button fixes a failure. A changed publisher
    /// waits in the report; `closeRunReport()` raises its sticky banner if it is still unsettled.
    func report(run: UpdateRunOutcome, planned: [OutdatedItem], caskOperationID: UUID? = nil,
                caskAppPaths: [String: URL] = [:], replacementOperations: [String: UUID] = [:]) {
        let summary = run.summary
        let report = UpdateRunReport.make(
            planned: planned, summary: summary,
            skippedKeys: updateInterruption.skippedKeys, heldForPasswordKeys: heldForPasswordKeys,
            wasStopped: updateInterruption.didSkipWork,
            startedAt: runBoard.startedAt, finishedAt: dependencies.now(),
            caskOperationID: caskOperationID, caskAppPaths: caskAppPaths,
            replacementOperations: replacementOperations, stillOutdatedKeys: stillOutdatedKeys,
            confirmed: Set(planned.map(\.kind)).isSubset(of: confirmedSourceKinds)
        )
        setRunReport(report)
        UpdateStageDiagnostics.recordSummary(summary)

        // OBS-02 — the summary closes with the window. The same run is also written to the
        // durable journal, so a bug report filed tomorrow can still say what happened today.
        dependencies.recordUpdateRun(
            UpdateJournalEntry(summary: summary, trigger: .manual, finishedAt: Date())
        )

        for outcome in summary.rollbackFailures {
            showStickyBanner(BannerData(variant: .danger,
                                        title: tr("Nie udało się cofnąć aktualizacji"),
                                        message: trf("%@: nowa wersja nie przeszła kontroli, a przywrócenie poprzedniej nie powiodło się. Sprawdź aplikację przed użyciem.", "\(outcome.name)"),
                                        action: .openLogs))
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
        if interrupted {
            reportInterruptedRun(upgraded: summary.upgraded.count)
            announcer.announce(AnnouncementCopy.runStopped(updated: report.updatedCount, total: report.plannedCount))
        } else {
            announcer.announce(AnnouncementCopy.runFinished(
                updated: report.updatedCount,
                total: report.plannedCount,
                needsAttention: report.namesNeedingAttention
            ))
        }
        // Success follows the report: every planned item updated. `summary.allItemsUpgraded`
        // sees only the items that produced an outcome, so a planned row that never got one
        // (a journal that failed before its lane) would have read "Gotowe!".
        if report.status == .finished {
            dependencies.defaults.set(true, forKey: ReadinessPresentation.dismissedKey)
            let count = report.updatedCount
            emitActivitySignal(.success)
            emitWegaState(WegaState(pose: .happy, line: trp("Gotowe! %@ pakietów odświeżonych.", count)))
            WegaLog.info(.homebrew, "Zaktualizowano \(count) pakietów")
            return
        }
        // A stop that left only untouched rows behind is a stop, and `reportInterruptedRun` said so.
        if interrupted && summary.allItemsUpgraded { return }

        let failedNames = summary.notUpgraded.map(\.name)
        let permission = BannerCopy.permissionNeeded(names: failedNames)
        // REL-05 — a missing "App Management" grant outranks the sudo hint: it explains the
        // whole failure, and its `stderr` ("ditto: …: Operation not permitted") is exactly the
        // line a user cannot act on. One named permission, one button that grants it. Any other
        // failure is the summary's to show: a banner only for a failure its button fixes.
        let appManagementTemplate = "%@ macOS nie pozwolił Wedze podmienić aplikacji w /Applications. Przyznaj uprawnienie „Zarządzanie aplikacjami” w Ustawieniach systemowych → Prywatność i bezpieczeństwo."
        // Owner decision 2026-11-21 — while the settings sudo reads cannot be trusted, Touch ID is
        // no advice: the card offers no sudo route, and Wega asked for nothing.
        let promptsHeld = (passwordHold ?? (summary.needsSudoPassword ? dependencies.sudoPolicyDistrust() : nil)) != nil
        let sudoTemplate = promptsHeld
            ? "%@ Cask wymaga hasła administratora, a ustawieniom, które czyta sudo, nie można teraz ufać, więc o nie nie poprosiłam. Co zrobić, mówi karta Touch ID w Ustawieniach."
            : "%@ Cask wymaga hasła administratora. Włącz Touch ID, żeby autoryzować aktualizacje odciskiem — bez wpisywania hasła."
        let sudoAction: BannerAction = promptsHeld ? .openTouchIDCard : .openSettings
        if summary.needsAppManagementPermission {
            showBanner(BannerData(
                variant: .danger,
                title: tr("Brak uprawnienia „Zarządzanie aplikacjami”"),
                message: trf(appManagementTemplate, permission.message),
                action: .openAppManagementSettings,
                fullMessage: permission.fullMessage.map { trf(appManagementTemplate, $0) }
            ))
        } else if summary.needsSudoPassword {
            showBanner(BannerData(variant: .danger,
                                  title: tr("Aktualizacja niekompletna"),
                                  message: trf(sudoTemplate, permission.message),
                                  action: sudoAction,
                                  fullMessage: permission.fullMessage.map { trf(sudoTemplate, $0) }))
        }
        emitActivitySignal(.error)
        emitWegaState(WegaState(pose: .alert, line: tr("Część pakietów się nie zaktualizowała.")))
        // Surface *why* each upgrade failed — the brew error block, not just the token
        // name — so the log explains the failure instead of only flagging it. The block
        // rides on the failure entry as one detail rather than as N loose lines, so
        // selecting that entry for a bug report carries the explanation with it. The headline
        // and the extra lines name the summary's rows: a row nothing attempted has no outcome
        // for `summary.notUpgraded` to list, and its note sends the user here.
        WegaLog.error(
            .homebrew,
            report.failureLogHeadline,
            detail: LogDetail(
                stderr: summary.diagnostics.joined(separator: "\n"),
                source: "cask"
            )
        )
        for outcome in summary.notUpgraded {
            WegaLog.error(.homebrew, "\(outcome.name): \(outcome.verdict.logDescription)")
        }
        for line in report.failureLogLinesBeyondTheSummary {
            WegaLog.error(.homebrew, line)
        }
    }

    /// Owner decision 2026-11-21 — right before the run starts, the gate reads the settings `sudo`
    /// reads. While they cannot be trusted, the casks that may ask for the administrator password
    /// (and those whose profile is unknown) are held from the start: they read „pomijam — może
    /// wymagać hasła” and the report names them. Returns the held tokens.
    func beginPasswordHold(plannedCaskNames: [String], planned: [OutdatedItem]) -> Set<String> {
        heldForPasswordKeys = []
        passwordHold = dependencies.sudoPolicyDistrust()
        guard let passwordHold else { return [] }
        UpdateDiagnostics.record("update.passwordHold", fields: ["distrust": passwordHold.logName])
        let held = Set(CaskUpgradeLanes(tokens: plannedCaskNames, profiles: caskProfiles).serial)
        for item in planned where item.kind == .cask && held.contains(item.name) {
            heldForPasswordKeys.insert(item.key)
            markRunRow(item.key, .heldForPassword)
        }
        return held
    }

    /// Folds one row's lane result into the run.
    ///
    /// A result with no outcome is a row the stop switch caught before it started: it is
    /// already recorded as skipped by `shouldStopUpdate`, and adding a verdict for it here
    /// would report on a row nothing ever attempted.
    func fold(_ result: LaneItemResult, into run: inout UpdateRunOutcome) {
        if let veto = result.publisherVeto {
            run.recordPublisherVetoes([result.item], audits: [result.item.name: veto])
        }
        guard let outcome = result.outcome else { return }
        run.record([result.item], outcome: outcome)
        if let validation = result.validation {
            run.applyValidation([result.item.name: validation])
        }
    }

    func restartApp(_ info: RestartInfo) async {
        let inherited = UpdateDiagnostics.current
        let trace = inherited ?? DiagnosticRun(trigger: "restart", subjects: [info.appName])
        defer { if inherited == nil { trace.finish() } }
        await UpdateDiagnostics.$current.withValue(trace) {
            await restartAppTraced(info)
        }
    }

    private func restartAppTraced(_ info: RestartInfo) async {
        var fields = ["processName": info.processName, "appName": info.appName, "engineReadiness": "notChecked"]
        if let operationID = restartDiagnosticOperationIDs[info.processName] {
            fields["operationID"] = operationID.uuidString
        }
        UpdateDiagnostics.record("restart.requested", fields: fields)
        if await handleDockerRestart(info, fields: fields) { return }
        restartBusy = info.processName
        let outcome = await gracefulRestartFlow().run(info)
        UpdateDiagnostics.record("restart.gracefulOutcome", fields: fields.merging(
            ["result": outcome == .relaunched ? "relaunched" : "needsForceConsent"],
            uniquingKeysWith: { _, new in new }))
        guard outcome == .relaunched else {
            pendingForceRestart = info
            restartBusy = nil
            return
        }
        restartCandidates.removeAll { $0.processName == info.processName }
        restartBusy = nil
        restartDiagnosticOperationIDs.removeValue(forKey: info.processName)
        UpdateDiagnostics.record("restart.flowCompleted", fields: fields)
    }

    private func gracefulRestartFlow() -> RestartFlow {
        let processes = processes
        return RestartFlow(
            requestQuit: { await processes.requestGracefulTermination(appName: $0.appName, processName: $0.processName) },
            isRunning: { await processes.isRunning($0) },
            launch: { await processes.launch(appName: $0) },
            pause: { try? await Task.sleep(for: $0) },
            forceKill: { await processes.forceKill($0) }
        )
    }

    func confirmForceRestart(_ info: RestartInfo) async {
        pendingForceRestart = nil
        restartBusy = info.processName
        defer { restartBusy = nil }
        guard await gracefulRestartFlow().force(info) == .relaunched else {
            showBanner(BannerData(
                variant: .danger,
                title: tr("Nie udało się zamknąć aplikacji"),
                message: trf("Nie mogę zamknąć %@. Zamknij ją ręcznie.", info.appName),
                action: .openLogs))
            return
        }
        restartCandidates.removeAll { $0.processName == info.processName }
        restartDiagnosticOperationIDs.removeValue(forKey: info.processName)
        UpdateDiagnostics.record("restart.flowCompleted", fields: ["processName": info.processName, "forced": "true"])
    }

    /// The force alert closed without an answer. The app stays open, as „Zostaw otwartą” leaves
    /// it, but no refusal is recorded — the user gave none. A dismissal for another app (a stale
    /// one) leaves the current prompt alone.
    func dismissForceRestartPrompt(_ info: RestartInfo) {
        guard pendingForceRestart?.processName == info.processName else { return }
        pendingForceRestart = nil
    }

    func keepAppOpen(_ info: RestartInfo) {
        pendingForceRestart = nil
        UpdateDiagnostics.record("restart.forceDeclined", fields: ["processName": info.processName])
    }
}
