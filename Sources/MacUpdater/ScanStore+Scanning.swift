import Foundation
import MacUpdaterCore

// MARK: - One scan round
//
// ARCH-08 — the scan: starting it, walking its phases, cancelling it, and settling what the
// sources answered. It owns nothing about *changing* the system; a round that finds nothing to
// do still runs entirely through here.
//
// Split out of `ScanStore+Actions.swift`, which had grown to hold every action the store can
// take. That file was split once before by length alone (`+Rollback`, `+Undo`); this one
// follows what the code is for, which is what the card asked for and what makes two cards
// touching different parts of scanning stop colliding on one file.
extension ScanStore {
    /// Kicks off a scan owned by the store. Idempotent: a second press while one is running
    /// is ignored rather than racing a second `brew update` against the first.
    func startCheck() {
        guard scanTask == nil else { return }
        scanTask = Task { @MainActor [weak self] in
            await self?.runCheck()
            self?.scanTask = nil
        }
    }

    /// M2(c) — cancellation is not new plumbing: `ProcessRunner` already honours
    /// `Task.isCancelled` end to end and surfaces `.cancelled`. It just had no button.
    func cancelScan() {
        scanTask?.cancel()
    }

    /// Returns `true` when the caller must stop. Freezes progress at the phase we reached,
    /// so the screen can say where it stopped instead of snapping to 0% or to "done".
    private func bailIfCancelled(at phase: ScanPhase, emitActivity: Bool) async -> Bool {
        guard Task.isCancelled else { return false }
        progress = .cancelled(at: phase)
        // Keep whatever the previous scan found rather than blanking the window: an empty
        // list would read as "nothing is outdated", which we have not established.
        status = lastCheck == nil ? .ready : .results
        if emitActivity { emitActivitySignal(.idle) }
        emitWegaState(WegaState(pose: .idle, line: tr("Przerwałam skanowanie.")))
        WegaLog.info(.scanner, "Skan anulowany na etapie: \(phase.commandLabel)")
        return true
    }

    /// `lightweight` skips the two expensive, redundant steps after an upgrade (M2d):
    /// `brew update` (metadata was refreshed minutes ago, at the start of the upgrade) and
    /// the stale-cask sweep (nothing has become stale in the meantime). What remains is a
    /// plain `brew outdated` re-query, which is all the post-upgrade list actually needs.
    func runCheck(
        emitActivity: Bool = true,
        lightweight: Bool = false,
        operationLease: OperationCoordinator.Lease? = nil
    ) async {
        guard let model else { return }
        status = .checking
        errorMessage = nil
        // Nothing is confirmed until each source has answered in this scan — a scan that
        // gets cancelled half-way must not leave last time's confirmations standing.
        confirmedSourceKinds = []
        if emitActivity { emitActivitySignal(.scanning) }
        WegaLog.info(.scanner, lightweight ? "Lekkie odświeżenie listy" : tr("Skan rozpoczęty"))
        emitWegaState(WegaState(pose: .sniff, line: tr("Węszę po Homebrew…")))

        progress = .running(.brew)
        var metadata: ScanSourceReport?
        if !lightweight {
            // Refresh brew metadata before asking what is outdated — otherwise a
            // newly-released cask/formula version that hasn't landed locally yet
            // would be missed even though `brew info` against the API shows it.
            metadata = await refreshBrewMetadata()
            if await bailIfCancelled(at: .brew, emitActivity: emitActivity) { return }
        }

        do {
            if let operationLease {
                try await OperationCoordinator.shared.withRead(
                    holding: operationLease,
                    label: "foreground post-upgrade scan"
                ) { @MainActor in
                    await self.runCheckReadPhases(
                        model: model,
                        emitActivity: emitActivity,
                        lightweight: lightweight,
                        metadata: metadata
                    )
                }
            } else {
                try await OperationCoordinator.shared.withReadLease(label: "foreground scan") { @MainActor _ in
                    await self.runCheckReadPhases(
                        model: model,
                        emitActivity: emitActivity,
                        lightweight: lightweight,
                        metadata: metadata
                    )
                }
            }
        } catch is CancellationError {
            _ = await bailIfCancelled(at: .brew, emitActivity: emitActivity)
        } catch {
            // UX-06 — the technical detail goes to the log; the user sees a localized message.
            WegaLog.error(.scanner, "Koordynacja skanu: \(error.localizedDescription)")
            errorMessage = tr("Sprawdzanie aktualizacji nie powiodło się — szczegóły w logu.")
            status = lastCheck == nil ? .ready : .results
            if emitActivity { emitActivitySignal(.error) }
        }
    }

    private func runCheckReadPhases(
        model: AppViewModel,
        emitActivity: Bool,
        lightweight: Bool,
        metadata: ScanSourceReport?
    ) async {
        // F4 — an absent tool is "not applicable", never a failure. `brewNotFound` used to
        // land in the generic catch below, so a machine without Homebrew wore a permanent
        // red "the list may be incomplete" banner over a list that was complete.
        var outcomes: [SourceCheckOutcome] = []
        // REL-09 — the same verdicts, kept per source and with the failure's own words, so
        // the snapshot on disk can say which source went silent instead of losing the fact.
        var reports = ScanSourceReports()
        if let metadata {
            reports.brewMetadata = metadata
            if metadata.didFail { outcomes.append(.failed("brew update")) }
        }

        if !lightweight {
            // M3(b) — detect stale casks; never uninstall them here. "Check for updates" is a
            // read-only operation, and `brew uninstall --force` behind that button was the
            // single most surprising thing Wega did. The user is offered the cleanup as a card
            // in the results (see `staleCasks`) and the tokens are filtered out of the outdated
            // list below, so deferring the removal cannot resurrect phantom outdated entries.
            let installedTokens = (try? await model.brewService.installedCasks()) ?? []
            if installedTokens.isEmpty {
                staleCasks = []
            } else {
                let installInfo = (try? await model.brewService.caskInstallationInfo(tokens: Array(installedTokens))) ?? []
                staleCasks = StaleCaskDetector().staleCasks(from: installInfo)
            }
        }

        let brewOutcome: SourceCheckOutcome

        do {
            // Stale casks are still reported outdated by brew even though their app is gone
            // — drop them here so the count only ever offers upgrades the user can install.
            brewOutdated = UpdatePlanner.excludingStaleCasks(
                try await model.brewService.outdatedGreedy(),
                staleTokens: staleCasks
            )
            brewOutcome = .succeeded
        }
        catch BrewServiceError.brewNotFound { brewOutdated = nil; brewOutcome = .notInstalled }
        catch { brewOutdated = nil
                brewOutcome = .failed("brew outdated")
                // UX-06 — raw error (incl. brew's stderr) to the log, localized copy to the user.
                WegaLog.error(.homebrew, "brew outdated: \(error.localizedDescription)")
                errorMessage = tr("Homebrew nie odpowiedział podczas sprawdzania — szczegóły w logu.") }
        outcomes.append(brewOutcome)
        reports.brew = ScanSourceReport(outcome: brewOutcome, error: errorMessage)
        if brewOutcome == .succeeded { confirmedSourceKinds.formUnion([.formula, .cask]) }
        if await bailIfCancelled(at: .brew, emitActivity: emitActivity) { return }

        progress = .running(.mas)
        do { masOutdated = try await model.masService.outdated(); outcomes.append(.succeeded)
             reports.mas = ScanSourceReport(outcome: .succeeded)
             confirmedSourceKinds.insert(.appStore) }
        catch MasServiceError.masNotFound { masOutdated = []; outcomes.append(.notInstalled)
                reports.mas = ScanSourceReport(outcome: .notInstalled) }
        catch { masOutdated = []
                outcomes.append(.failed("Mac App Store"))
                // UX-06 — technical detail stays in the log; the report carries a localized reason.
                WegaLog.error(.app, "mas outdated: \(error.localizedDescription)")
                reports.mas = ScanSourceReport(outcome: .failed("Mac App Store"), error: tr("Mac App Store nie odpowiedział podczas sprawdzania — szczegóły w logu.")) }

        if await bailIfCancelled(at: .mas, emitActivity: emitActivity) { return }

        progress = .running(.npm)
        do { npmOutdated = try await model.npmService.outdated(); outcomes.append(.succeeded)
             reports.npm = ScanSourceReport(outcome: .succeeded)
             confirmedSourceKinds.insert(.npm) }
        catch NpmServiceError.npmNotFound { npmOutdated = []; outcomes.append(.notInstalled)
                reports.npm = ScanSourceReport(outcome: .notInstalled) }
        catch { npmOutdated = []
                outcomes.append(.failed("npm"))
                // UX-06 — technical detail stays in the log; the report carries a localized reason.
                WegaLog.error(.network, "npm outdated: \(error.localizedDescription)")
                reports.npm = ScanSourceReport(outcome: .failed("npm"), error: tr("npm nie odpowiedział podczas sprawdzania — szczegóły w logu.")) }

        var failed = UpdatePlanner.failedSourceCount(outcomes)
        // Names of the top-level sources that genuinely went silent, for the scan-end
        // log (each manual-checker failure is logged individually by ManualUpdateScanner).
        var silentSources = UpdatePlanner.failedSourceNames(outcomes)
        unavailableSources = UpdatePlanner.unavailableSourceCount(outcomes)
        brewAvailable = brewOutcome != .notInstalled

        if await bailIfCancelled(at: .npm, emitActivity: emitActivity) { return }

        progress = .running(.manual)
        let brewOutdatedCasks = Set(brewOutdated?.casks.map(\.name) ?? [])
        let scan = await scanManualUpdates(brewOutdatedCasks: brewOutdatedCasks)
        manualOutdated = scan.apps
        failed += scan.failedChecks
        if scan.failedChecks > 0 { silentSources.append("ręczne checki (\(scan.failedChecks))") }
        reports.manual = scan.failedChecks > 0
            ? ScanSourceReport(outcome: .failed("ręczne checki"),
                               error: "ręczne checki: \(scan.failedChecks) źródeł nie odpowiedziało")
            : ScanSourceReport(outcome: .succeeded)

        // Resolve icon paths for outdated casks, and drop entries whose real
        // bundle version already matches `current_version` (self-updating apps
        // like Chrome bump their bundle behind brew's back).
        if let casks = brewOutdated?.casks, !casks.isEmpty {
            let infos = (try? await model.brewService.caskInstallationInfo(tokens: casks.map(\.name))) ?? []

            let drifted = BrewCaskDriftFilter().driftedTokens(outdated: casks, installationInfo: infos)
            if !drifted.isEmpty, var updated = brewOutdated {
                updated.casks.removeAll { drifted.contains($0.name) }
                brewOutdated = updated
            }

            caskIconPaths = CaskAppPathResolver().appPaths(from: infos, excluding: drifted)
        }

        // FEAT-03: transparentność pobrania (host + checksum) dla outdated casków.
        if let casks = brewOutdated?.casks, !casks.isEmpty {
            let infos = (try? await model.brewService.caskDownloadInfo(tokens: casks.map(\.name))) ?? []
            caskDownloads = Dictionary(infos.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            caskDownloads = [:]
        }

        await resolveRollbackProtection()

        lastCheck = Date()
        status    = .results
        progress  = .finished
        // REL-09 — the per-source picture is part of the result from here on: it decides
        // what gets persisted, and whether an empty list may call itself "up to date".
        applyScanSourceReports(reports)

        finishScan(emitActivity: emitActivity, silentSources: silentSources, failedSources: failed)
    }

    /// REL-09 — refresh Homebrew's metadata and **report** what happened.
    ///
    /// This used to run as `_ = try? await …update()`. Offline, brew then computed the
    /// outdated list from a stale index and the window presented the result as if every
    /// source had spoken. Note `update()` does not throw on a non-zero exit — there is no
    /// `ensureSuccess` on it — so the exit code is the signal that matters here.
    private func refreshBrewMetadata() async -> ScanSourceReport {
        guard let model else { return ScanSourceReport(outcome: .notInstalled) }
        do {
            let result = try await UpgradeCoordinator.shared.performWrite(.brewMetadata) {
                let ticket = MutationGuard.shared.begin(tr("aktualizacja Homebrew"))
                defer { MutationGuard.shared.end(ticket) }
                return try await model.brewService.update()
            }
            guard result.exitCode != 0 else { return ScanSourceReport(outcome: .succeeded) }
            let stderr = result.stderr.components(separatedBy: "\n").first { !$0.isEmpty }
            let reason = stderr ?? "kod wyjścia \(result.exitCode)"
            WegaLog.error(.homebrew, "brew update: \(reason)")
            return ScanSourceReport(outcome: .failed("brew update"), error: "brew update: \(reason)")
        } catch BrewServiceError.brewNotFound {
            return ScanSourceReport(outcome: .notInstalled)
        } catch {
            WegaLog.error(.homebrew, "brew update: \(error.localizedDescription)")
            return ScanSourceReport(outcome: .failed("brew update"),
                                    error: "brew update: \(error.localizedDescription)")
        }
    }

    /// Reports a finished scan: structured log (breakdown + per-item lines), the tab-icon
    /// status (green/red, unless suppressed for the upgrade flow), the result banner, and
    /// the badge/error counts. Split out of `runCheck` to keep that method's complexity down.
    private func finishScan(emitActivity: Bool, silentSources: [String], failedSources sources: Int) {
        failedSources = sources
        let total = allItems.count + visibleManual.count
        let breakdown = ScanLog.breakdown(items: allItems, manual: visibleManual)
        let silent = silentSources.isEmpty
            ? "wszystkie źródła odpowiedziały"
            : "milczały: \(silentSources.joined(separator: ", "))"
        WegaLog.info(.scanner, "Skan zakończony: \(total) aktualizacji (\(breakdown)) — \(silent)")
        for line in ScanLog.foundLines(items: allItems, manual: visibleManual) {
            WegaLog.info(.scanner, "• \(line)")
        }
        let scanState = UpdatePlanner.scanState(updateCount: total, failedChecks: sources)
        // Tab-icon status: green when the scan completed, red when a source failed.
        // Suppressed when called from `runUpdate` (emitActivity == false), which owns
        // the icon for the whole upgrade flow and sets the final state itself.
        if emitActivity {
            switch scanState {
            case .upToDate, .outdated:          emitActivitySignal(.success)
            case .checkFailed, .partialFailure: emitActivitySignal(.error)
            }
        }
        switch scanState {
        case .upToDate:
            if let msg = errorMessage {
                showBanner(BannerData(variant: .danger, title: tr("Błąd Homebrew"), message: msg, action: .openLogs))
            }
            emitWegaState(WegaState(pose: .happy, line: tr("Wszystko aktualne. Idę się zdrzemnąć.")))
        case .outdated(let n):
            if let msg = errorMessage {
                showBanner(BannerData(variant: .danger, title: tr("Błąd Homebrew"), message: msg, action: .openLogs))
            }
            emitWegaState(WegaState(pose: .alert, line: trf("Znalazłam %@ rzeczy do uporządkowania.", "\(n)")))
        case .checkFailed:
            showBanner(BannerData(variant: .danger,
                                  title: tr("Nie udało się sprawdzić aktualizacji"),
                                  message: errorMessage ?? tr("Część źródeł nie odpowiedziała — sprawdź połączenie z internetem i spróbuj ponownie."),
                                  action: .openLogs))
            emitWegaState(WegaState(pose: .sad, line: tr("Nie dowęszyłam się — chyba nie ma internetu.")))
        case .partialFailure(let updates, let failed):
            showBanner(BannerData(variant: .danger,
                                  title: tr("Lista może być niepełna"),
                                  message: trf("Znalazłam %@ aktualizacji, ale %@ źródeł nie odpowiedziało — sprawdź połączenie i odśwież.", "\(updates)", "\(failed)"),
                                  action: .openLogs))
            emitWegaState(WegaState(pose: .alert, line: trf("Znalazłam %@, ale część źródeł milczy.", "\(updates)")))
        }
        // M4 — the dock badge has one owner (the agent); a window scan hands it the fresh
        // number instead of leaving yesterday's. Only from here, never from `emitCounts()`,
        // which also runs on a bare view rebuild and must not claim a scan just happened.
        MenuBarAgent.shared.reportWindowScan(
            count: updateCount.badgeCount,
            failedChecks: sources,
            fingerprint: UpdateFingerprint.of(items: allItems, manual: visibleManual)
        )
        emitCounts()
        persistLastScan()
    }

    private func scanManualUpdates(brewOutdatedCasks: Set<String> = []) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        guard let model else { return ([], 0) }
        return await ManualUpdateScanner(brewService: model.brewService).scan(brewOutdatedCasks: brewOutdatedCasks)
    }
}
