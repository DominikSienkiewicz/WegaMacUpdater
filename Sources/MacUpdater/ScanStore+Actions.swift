import Foundation
import MacUpdaterCore

private struct ForegroundCaskPreparation {
    let appPaths: [String: URL]
    let snapshots: [String: URL]
    let trustedCaskNames: [String]
    let publisherVetoes: [String: TeamIDAudit]
}

private enum ForegroundCaskPreparationResult {
    case ready(ForegroundCaskPreparation)
    case blocked(publisherVetoes: [String: TeamIDAudit])
}

// MARK: - Scan & update actions
//
// The half of `ScanStore` that *produces* a result — the scan, the upgrade, and the
// rollback net around it — kept apart from the half that *holds* one. Together they had
// outgrown SwiftLint's file_length budget; this is the seam the type already had, so the
// split follows it rather than inventing one.
//
// This extension used to live in `ScanStore.swift`, where `private` state stayed reachable.
// Across files it is not, so the members it needs — `model`, `processes`, `scanTask`,
// `confirmedSourceKinds`, `failedSources`, and the emit/banner/persist helpers — are
// `internal` there instead of `private`. `sourceReports` and `lastScanComplete` keep their
// `private(set)`: they are written through `applyScanSourceReports(_:)`, so the view tree
// still cannot assign them.
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
            errorMessage = error.localizedDescription
            status = lastCheck == nil ? .ready : .results
            if emitActivity { emitActivitySignal(.error) }
            WegaLog.error(.scanner, "Koordynacja skanu: \(error.localizedDescription)")
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
        catch { errorMessage = error.localizedDescription; brewOutdated = nil
                brewOutcome = .failed("brew outdated")
                WegaLog.error(.homebrew, "brew outdated: \(error.localizedDescription)") }
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
                reports.mas = ScanSourceReport(outcome: .failed("Mac App Store"), error: "mas outdated: \(error.localizedDescription)")
                WegaLog.error(.app, "mas outdated: \(error.localizedDescription)") }

        if await bailIfCancelled(at: .mas, emitActivity: emitActivity) { return }

        progress = .running(.npm)
        do { npmOutdated = try await model.npmService.outdated(); outcomes.append(.succeeded)
             reports.npm = ScanSourceReport(outcome: .succeeded)
             confirmedSourceKinds.insert(.npm) }
        catch NpmServiceError.npmNotFound { npmOutdated = []; outcomes.append(.notInstalled)
                reports.npm = ScanSourceReport(outcome: .notInstalled) }
        catch { npmOutdated = []
                outcomes.append(.failed("npm"))
                reports.npm = ScanSourceReport(outcome: .failed("npm"), error: "npm outdated: \(error.localizedDescription)")
                WegaLog.error(.network, "npm outdated: \(error.localizedDescription)") }

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

    func installManual(token: String) async {
        await UpgradeCoordinator.shared.performWrite(.manualInstall) {
            await self.installManualCoordinated(token: token)
        }
    }

    private func installManualCoordinated(token: String) async {
        guard let model, manualBusy == nil else { return }
        guard UpgradeMutex.shared.acquire() else {
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja w toku"),
                                  message: tr("Wega właśnie aktualizuje coś w tle. Spróbuj za chwilę.")))
            return
        }
        defer { UpgradeMutex.shared.release() }
        manualBusy = token
        defer { manualBusy = nil }
        let ticket = MutationGuard.shared.begin(trf("instalacja %@", "\(token)"))
        defer { MutationGuard.shared.end(ticket) }
        emitActivitySignal(.scanning)
        let installArgs = BrewService.adoptCaskArguments(token: token)
        brewLog = ["$ brew " + installArgs.joined(separator: " ")]
        showLog = true
        WegaLog.info(.homebrew, "Uruchamiam: brew \(installArgs.joined(separator: " "))")
        emitWegaState(WegaState(pose: .sniff, line: trf("Instaluję %@ przez Brew…", "\(token)")))

        guard let appURL = manualOutdated.first(where: {
            if case .cask(let candidate) = $0.source { return candidate == token }
            return false
        })?.path else {
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja odroczona"),
                                  message: tr("Nie udało się utworzyć wymaganego snapshotu.")))
            emitActivitySignal(.error)
            return
        }

        let preparation: CaskReplacementSafety.Preparation
        switch await CaskReplacementSafety.prepare(
            token: token,
            appURL: appURL,
            brewService: model.brewService
        ) {
        case .ready(let ready):
            preparation = ready
        case .resourcePostponed(let reason):
            brewLog.append("⏸ " + trf("Aktualizacja odroczona: %@.", "\(reason)"))
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja odroczona"),
                                  message: trf("Bramka zasobów: %@.", "\(reason)")))
            emitActivitySignal(.error)
            return
        case .publisherRejected(let old, let new):
            let message = trf("%@: Team ID zmienił się (%@ → %@). Zweryfikuj.",
                              "\(token)", "\(old)", "\(new ?? "—")")
            brewLog.append("⏸ " + message)
            showBanner(BannerData(variant: .danger, title: tr("Zmiana wydawcy"), message: message))
            emitActivitySignal(.error)
            return
        case .snapshotFailed:
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja odroczona"),
                                  message: tr("Nie udało się utworzyć wymaganego snapshotu.")))
            emitActivitySignal(.error)
            return
        }

        var installError: Error?
        var exitCode: Int32 = 0
        do {
            let stream = try model.brewService.events(arguments: installArgs)
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
                    brewLog.append(contentsOf: lines)
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            installError = error
        }

        let installedAppURL = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: model.brewService
        )
        let verification = await CaskReplacementSafety.verify(
            preparation,
            installedAppURL: installedAppURL
        )
        guard reportManualReplacementVerification(verification, token: token) else { return }

        if let installError {
            showBanner(BannerData(variant: .danger, title: tr("Błąd instalacji"),
                                  message: installError.localizedDescription))
            emitActivitySignal(.error)
            emitWegaState(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
            WegaLog.error(.homebrew, "Instalacja \(token): \(installError.localizedDescription)")
        } else if exitCode == 0 {
            manualOutdated.removeAll {
                if case .cask(let t) = $0.source { return t == token }
                return false
            }
            showBanner(BannerData(variant: .success, title: trf("Zaktualizowano %@", "\(token)"),
                                  message: tr("Teraz zarządzany przez Homebrew.")))
            emitActivitySignal(.success)
            emitWegaState(WegaState(pose: .happy, line: trf("%@ zaktualizowany i pod opieką Brew.", "\(token)")))
            WegaLog.info(.homebrew, "Zainstalowano \(token) (brew cask)")
        } else {
            showBanner(BannerData(variant: .danger, title: trf("Błąd instalacji %@", "\(token)"),
                                  message: tr("Sprawdź logi poniżej.")))
            emitActivitySignal(.error)
            emitWegaState(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
            let reason = ScanLog.brewErrorReason(from: brewLog).map { ": \($0)" } ?? ""
            WegaLog.error(.homebrew, "Instalacja \(token) nieudana (kod \(exitCode))\(reason)")
        }
    }

    private func reportManualReplacementVerification(
        _ verdict: CaskValidationVerdict,
        token: String
    ) -> Bool {
        let title: String
        let message: String
        switch verdict {
        case .healthy:
            return true
        case .rolledBack:
            title = tr("Aktualizacja niekompletna")
            message = trf("%@: nowa wersja nie przeszła kontroli — przywrócono poprzednią.", "\(token)")
        case .rollbackFailed:
            title = tr("Rollback się nie powiódł")
            message = trf(
                "%@: nowa wersja nie przeszła kontroli, a przywrócenie poprzedniej nie powiodło się. Sprawdź aplikację przed użyciem.",
                "\(token)"
            )
        case .publisherChanged(let old, let new):
            title = tr("Zmiana wydawcy")
            message = trf("%@: Team ID zmienił się (%@ → %@). Zweryfikuj.",
                          "\(token)", "\(old)", "\(new ?? "—")")
        case .publisherChangedAndRolledBack(let old, let new):
            title = tr("Zmiana wydawcy")
            message = trf("%@: Team ID zmienił się (%@ → %@). Przywrócono poprzednią zaufaną wersję.",
                          "\(token)", "\(old)", "\(new ?? "—")")
        }
        brewLog.append("⚠️ " + message)
        showBanner(BannerData(variant: .danger, title: title, message: message))
        emitActivitySignal(.error)
        emitWegaState(WegaState(pose: .alert, line: trf("Coś poszło nie tak z %@.", "\(token)")))
        WegaLog.error(.homebrew, message)
        return false
    }

    private func prepareForegroundCasks(
        _ caskNames: [String],
        targetKeys: Set<String>
    ) async -> ForegroundCaskPreparationResult {
        await probeDownloadSizes(targetKeys: targetKeys)
        let appPaths = await resolveCaskAppPaths(caskNames)
        let resourceDecision = await foregroundResourceDecision(caskNames, appPaths: appPaths)
        guard case .allow = resourceDecision else {
            guard case .postpone(let reason) = resourceDecision else {
                return .blocked(publisherVetoes: [:])
            }
            brewLog.append("⏸ " + trf("Aktualizacja odroczona: %@.", "\(reason)"))
            WegaLog.info(.homebrew, "Aktualizacja z okna odroczona — \(reason).")
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja odroczona"),
                                  message: trf("Bramka zasobów: %@.", "\(reason)")))
            emitActivitySignal(.error)
            emitWegaState(WegaState(pose: .alert, line: tr("Warunki nie pozwalają teraz bezpiecznie pobrać aktualizacji.")))
            return .blocked(publisherVetoes: [:])
        }

        let publisherVetoes = CaskRollbackGuard.publisherVetoes(
            tokens: caskNames, appPaths: appPaths
        )
        let caskNames = caskNames.filter { publisherVetoes[$0] == nil }
        let snapshots = snapshotCasks(caskNames, appPaths: appPaths)
        let missing = caskNames.filter { appPaths[$0] != nil && snapshots[$0] == nil }
        guard missing.isEmpty else {
            for snapshot in snapshots.values { try? FileManager.default.removeItem(at: snapshot) }
            let names = missing.joined(separator: ", ")
            brewLog.append("⏸ " + trf("Nie udało się utworzyć snapshotu dla: %@.", "\(names)"))
            WegaLog.error(.homebrew, "Aktualizacja z okna odroczona — brak snapshotu: \(names).")
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja odroczona"),
                                  message: tr("Nie udało się utworzyć wymaganego snapshotu.")))
            emitActivitySignal(.error)
            return .blocked(publisherVetoes: publisherVetoes)
        }
        return .ready(ForegroundCaskPreparation(
            appPaths: appPaths,
            snapshots: snapshots,
            trustedCaskNames: caskNames,
            publisherVetoes: publisherVetoes
        ))
    }

    private func foregroundResourceDecision(
        _ caskNames: [String],
        appPaths: [String: URL]
    ) async -> DownloadGate.Decision {
        let sizes = Dictionary(
            uniqueKeysWithValues: caskNames.map { ($0, caskSizes[$0] ?? .unknown) }
        )
        return await DownloadResourcePreflight.decision(
            tokens: caskNames,
            downloadSizes: sizes,
            appPaths: appPaths
        )
    }

    func runUpdate(targetKeys: Set<String>) async {
        do {
            try await UpgradeCoordinator.shared.performWriteLease(.foregroundUpgrade) { lease in
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

        let plan          = UpdatePlanner.plan(selectedKeys: targetKeys, allKeys: allItems.map(\.key))
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
        let npmCommands   = commands.filter { $0.executable == "npm" }
        let plannedCaskNames = plan.caskNames
        let npmNames      = plan.npmNames
        let masAppStoreIDs = plan.masAppStoreIDs

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

        // Pre-capture which casks being updated are currently running
        var candidates: [RestartInfo] = []
        for token in plannedCaskNames {
            if let info = MacUpdaterConstants.restartMap[token], await isProcessRunning(info.processName) {
                candidates.append(info)
            }
        }

        // REL-02 — one outcome per item and source, filled in phase by phase (execution →
        // validation → rollback → rescan). Nothing announces success before every phase
        // that applies to an item has had its say.
        var run = UpdateRunOutcome()

        // Brew upgrade — formulae
        if let formulaArgs {
            run.record(plannedItems.filter { $0.kind == .formula }, outcome: await runBrewUpgrade(arguments: formulaArgs))
        }

        // Brew upgrade — casks (FEAT-05 snapshot przed, canary/rollback + FEAT-04 ledger po)
        if caskArgs != nil, let caskPreparation {
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
                let trustedCaskArgs = UpdatePlanner.caskUpgradeCommand(tokens: caskNames).arguments
                var caskOutcome = await runBrewUpgrade(arguments: trustedCaskArgs)

                // Auto-recover an interrupted upgrade: if a cask bailed because a stale
                // staged app from a previous, cut-short upgrade is in the way ("already an
                // App at …"), retry just those casks once with --force, which overwrites
                // the leftover. Without this they fail on every attempt until cleaned by hand.
                let retryTokens = caskOutcome.tokensRetryableWithForce
                if !retryTokens.isEmpty {
                    brewLog.append("↻ " + trf("Przerwana aktualizacja (%@) — ponawiam z --force.", "\(retryTokens.joined(separator: ", "))"))
                    WegaLog.info(.homebrew, "Przerwana aktualizacja casku — ponawiam z --force: \(retryTokens.joined(separator: ", "))")
                    let retryOutcome = await runBrewUpgrade(arguments: UpdatePlanner.forcedCaskCommand(tokens: retryTokens).arguments)
                    caskOutcome = BrewUpgradeOutcome.merging(original: caskOutcome, forcedRetry: retryOutcome, retriedTokens: retryTokens)
                }

                let trustedItems = plannedItems.filter {
                    $0.kind == .cask && caskNames.contains($0.name)
                }
                run.record(trustedItems, outcome: caskOutcome)
                // The canary/rollback verdict is a phase of the same result, not an aside: it
                // used to be raised after the summary had already been computed, so a cask the
                // guard had just rolled back still counted towards "Zaktualizowano N pakietów".
                run.applyValidation(await postCaskUpgrade(caskNames, appPaths: appPaths, snapshots: snapshots))
            }
        }

        // npm global upgrade — one package at a time (npm semantics).
        for (pkg, command) in zip(npmNames, npmCommands) {
            let outcome = await runNpmUpgrade(name: pkg, arguments: command.arguments)
            run.record(plannedItems.filter { $0.kind == .npm && $0.name == pkg }, outcome: outcome)
        }

        // MAS upgrade — the IDs are load-bearing. A bare `mas upgrade` expands to every
        // outdated App Store app, including rows outside the visible/confirmed UX-01 set.
        // mas still reports no per-app result, so one failure becomes a synthetic outcome
        // per planned item, exactly as `runNpmUpgrade` does.
        if !masAppStoreIDs.isEmpty {
            brewLog.append("$ mas upgrade " + masAppStoreIDs.joined(separator: " "))
            var masFailure: String?
            do {
                let result = try await model.masService.upgrade(appStoreIDs: masAppStoreIDs)
                let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
                brewLog.append(contentsOf: lines)
            } catch {
                masFailure = error.localizedDescription
                brewLog.append("error: \(error.localizedDescription)")
                WegaLog.error(.app, "mas upgrade: \(error.localizedDescription)")
            }
            run.record(masItems: plannedItems.filter { $0.kind == .appStore }, failure: masFailure)
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
        // M2(d) — lightweight: no second `brew update`, no second stale-cask sweep.
        await runCheck(emitActivity: false, lightweight: true, operationLease: operationLease)

        updating = false

        // The rescan is the last phase an item has to clear: whatever the tool claimed, an
        // item the fresh list still reports was not updated, and a rescan that could not
        // answer leaves the upgrade unconfirmed rather than confirmed-good.
        run.applyRescan(stillOutdatedKeys: Set(allItems.map(\.key)),
                        confirmed: Set(plannedItems.map(\.kind)).isSubset(of: confirmedSourceKinds))

        report(run: run)
    }

    /// Turns the run into what the user sees: the sticky alerts first (a failed rollback and
    /// a changed publisher are the two things that must not be missable), then the summary
    /// banner — green only when every item cleared every phase.
    private func report(run: UpdateRunOutcome) {
        let summary = run.summary

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

        if summary.allItemsUpgraded {
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
        let detail = summary.needsSudoPassword
            ? trf("%@ Cask wymaga hasła administratora. Włącz Touch ID, żeby autoryzować aktualizacje odciskiem — bez wpisywania hasła.", "\(baseDetail)")
            : baseDetail
        showBanner(BannerData(variant: .danger,
                              title: tr("Aktualizacja niekompletna"),
                              message: detail,
                              action: summary.needsSudoPassword ? .openSettings : nil))
        emitActivitySignal(.error)
        emitWegaState(WegaState(pose: .alert, line: tr("Część pakietów się nie zaktualizowała.")))
        WegaLog.error(.homebrew, "Aktualizacja niekompletna: \(failedNames.isEmpty ? "Brew zgłosił błąd" : failedNames.joined(separator: ", "))")
        // Surface *why* each upgrade failed — the brew error block, not just the token
        // name — so the log explains the failure instead of only flagging it.
        for line in summary.diagnostics {
            WegaLog.error(.homebrew, line)
        }
        for outcome in summary.notUpgraded {
            WegaLog.error(.homebrew, "\(outcome.name): \(outcome.verdict.logDescription)")
        }
    }

    /// Runs `brew <arguments>` streaming output to the log, and returns an
    /// outcome that reflects whether brew *actually* succeeded — exit code 0
    /// alone is unreliable for cask upgrades.
    private func runBrewUpgrade(arguments: [String]) async -> BrewUpgradeOutcome {
        guard let model else { return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: []) }
        brewLog.append("$ brew \(arguments.joined(separator: " "))")
        var captured = ""
        var exitCode: Int32 = 0
        do {
            let stream = try model.brewService.events(arguments: arguments)
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    captured += chunk
                    let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
                    brewLog.append(contentsOf: lines)
                    if brewLog.count > 500 { brewLog.removeFirst(brewLog.count - 500) }
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: [error.localizedDescription])
        }
        return BrewUpgradeOutcome.analyze(exitCode: exitCode, output: captured)
    }

    private func runNpmUpgrade(name: String, arguments: [String]) async -> BrewUpgradeOutcome {
        guard let model else { return BrewUpgradeOutcome(exitCode: -1, failedTokens: [name], errorLines: []) }
        brewLog.append("$ npm " + arguments.joined(separator: " "))
        var exitCode: Int32 = 0
        do {
            let stream = try model.npmService.upgradeEvents(name: name)
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
                    brewLog.append(contentsOf: lines)
                    if brewLog.count > 500 { brewLog.removeFirst(brewLog.count - 500) }
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [name], errorLines: [error.localizedDescription])
        }
        return BrewUpgradeOutcome(
            exitCode: exitCode,
            failedTokens: exitCode == 0 ? [] : [name],
            errorLines: []
        )
    }

    // MARK: FEAT-05 (rollback) + FEAT-04 (watchdog Team ID)

    /// REL-03 — where the casks in this run keep their `.app` bundles, resolved at upgrade
    /// time and **returned** so the phases that need it are handed it explicitly.
    ///
    /// `caskIconPaths` is only ever filled by a full `runCheck`, so in the most ordinary
    /// session there is — launch, look at the restored list, press "Zaktualizuj wszystkie" —
    /// it was empty, `CaskRollbackGuard` cloned nothing and `verify` skipped every token.
    /// Whatever the last scan did resolve for these tokens is kept as a fallback: a
    /// `brew info` that cannot answer now must not take the net down with it.
    private func resolveCaskAppPaths(_ tokens: [String]) async -> [String: URL] {
        guard let model, !tokens.isEmpty else { return [:] }
        let infos = (try? await model.brewService.caskInstallationInfo(tokens: tokens)) ?? []
        let resolved = CaskAppPathResolver().appPaths(from: infos)
        return caskIconPaths
            .filter { tokens.contains($0.key) }
            .merging(resolved) { _, fresh in fresh }
    }

    /// FEAT-05 + FEAT-04, now shared with the background updater so the two can never
    /// diverge on what "safe upgrade" means. See `CaskRollbackGuard`.
    ///
    /// `appPaths` is a parameter, not a field read on the way past (REL-03): a snapshot that
    /// cannot be taken without being told which bundles it covers is a snapshot no future
    /// call site can quietly take of nothing.
    private func snapshotCasks(_ tokens: [String], appPaths: [String: URL]) -> [String: URL] {
        CaskRollbackGuard.snapshot(tokens: tokens, appPaths: appPaths)
    }

    /// Runs the canary/rollback chain and **returns** its verdicts, so they can join the
    /// run's per-item result. It used to only narrate into the collapsible log, which is how
    /// `.rollbackFailed` — the case that must never be silent — ended under a green banner.
    ///
    /// Takes the same `appPaths` the snapshot was made from: verifying against a second,
    /// separately obtained map is how `verify` came to skip the tokens it had just cloned.
    private func postCaskUpgrade(_ tokens: [String], appPaths: [String: URL], snapshots: [String: URL]) async -> [String: CaskValidationVerdict] {
        let verdicts = await CaskRollbackGuard.verify(tokens: tokens, appPaths: appPaths, snapshots: snapshots)
        for (token, verdict) in verdicts {
            switch verdict {
            case .healthy, .publisherChanged:
                continue
            case .publisherChangedAndRolledBack:
                brewLog.append("⚠️ " + trf("%@: zmienił się Team ID wydawcy — przywrócono poprzednią zaufaną wersję.", "\(token)"))
                emitWegaState(WegaState(pose: .alert,
                                        line: trf("Cofnęłam %@ — zmienił się wydawca.", "\(token)")))
            case .rolledBack:
                brewLog.append("⚠️ " + trf("%@: nowa wersja nie przeszła kontroli — przywrócono poprzednią.", "\(token)"))
                emitWegaState(WegaState(pose: .alert, line: trf("Cofnęłam %@ — nowa wersja nie przeszła kontroli.", "\(token)")))
            case .rollbackFailed:
                brewLog.append("⚠️ " + trf("%@: nowa wersja nie przeszła kontroli, ale rollback się nie powiódł.", "\(token)"))
            }
        }
        return verdicts
    }

    private func isProcessRunning(_ name: String) async -> Bool {
        await processes.isRunning(name)
    }

    /// M5 — works out which outdated casks the rollback net actually covers.
    ///
    /// A cask that installs no `.app` cannot be snapshotted, so `postCaskUpgrade` has always
    /// skipped it — silently, with no log line and no hint in the UI. The hole cannot be
    /// closed (there is nothing to clone), only disclosed: the row gets an honest "no
    /// protection" badge, and the log says so before the upgrade runs, not after.
    private func resolveRollbackProtection() async {
        guard let model, let casks = brewOutdated?.casks, !casks.isEmpty else {
            caskProtection = [:]
            caskProfiles = [:]
            return
        }
        let profiles = (try? await model.brewService.caskArtifactProfiles(tokens: casks.map(\.name))) ?? []
        var verdicts: [String: RollbackProtection.Verdict] = [:]
        for profile in profiles {
            let verdict = RollbackProtection.evaluate(profile: profile)
            verdicts[profile.token] = verdict
            if verdict.deservesWarning {
                WegaLog.error(.homebrew,
                              "\(profile.token): brak ochrony rollbackiem — cask nie instaluje aplikacji, nie da się zrobić snapshotu.")
            }
        }
        caskProtection = verdicts
        caskProfiles = Dictionary(profiles.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        // Sizes are a network round-trip per cask; they are not worth paying for until the
        // user asks to see the plan.
        caskSizes = [:]
    }

    /// F2 — the exact commands the upgrade will run, from the same planner call the upgrade
    /// itself uses. If this ever disagrees with execution, it is because someone rebuilt an
    /// argument vector by hand.
    func plannedCommands(targetKeys: Set<String>) -> [UpdateCommand] {
        UpdatePlanner.commands(for: UpdatePlanner.plan(selectedKeys: targetKeys, allKeys: allItems.map(\.key)))
    }

    /// The casks this run would upgrade, in the order the command lists them.
    func plannedCaskTokens(targetKeys: Set<String>) -> [String] {
        UpdatePlanner.plan(selectedKeys: targetKeys, allKeys: allItems.map(\.key)).caskNames
    }

    /// F2 — one HEAD per cask, on demand. `brew info --json` has no size field (verified),
    /// and a CDN may withhold `Content-Length`, so "unknown" is a legitimate answer that the
    /// panel shows verbatim rather than guessing a number.
    func probeDownloadSizes(targetKeys: Set<String>) async {
        guard !probingSizes else { return }
        probingSizes = true
        defer { probingSizes = false }

        let probe = DownloadSizeProbe()
        for token in plannedCaskTokens(targetKeys: targetKeys) where caskSizes[token] == nil {
            guard let url = caskDownloads[token]?.url else { continue }
            caskSizes[token] = await probe.probe(urlString: url)
        }
    }

    /// M3(b) — the cleanup the scan used to perform silently, now behind the user's consent.
    func cleanUpStaleCasks() async {
        await UpgradeCoordinator.shared.performWrite(.cleanup) {
            await self.cleanUpStaleCasksCoordinated()
        }
    }

    private func cleanUpStaleCasksCoordinated() async {
        guard let model, !cleaningStaleCasks, !staleCasks.isEmpty else { return }
        let ticket = MutationGuard.shared.begin(tr("czyszczenie Homebrew"))
        defer { MutationGuard.shared.end(ticket) }
        cleaningStaleCasks = true
        defer { cleaningStaleCasks = false }

        var removed: [String] = []
        for token in staleCasks {
            if (try? await model.brewService.uninstallCask(token: token, force: true)) != nil {
                removed.append(token)
            } else {
                WegaLog.error(.homebrew, "Nie udało się usunąć nieaktualnego casku: \(token)")
            }
        }
        staleCasks.removeAll { removed.contains($0) }
        WegaLog.info(.homebrew, "Usunięto nieaktualne caski: \(removed.joined(separator: ", "))")
        showBanner(BannerData(variant: .success,
                              title: trf("Usunięto %@ nieaktualnych casków", "\(removed.count)"),
                              message: tr("Homebrew nie śledzi już aplikacji, których nie ma na dysku.")))
    }

    /// The user does not want to clean up now. Drop the card for this scan.
    func dismissStaleCasks() {
        staleCasks = []
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
