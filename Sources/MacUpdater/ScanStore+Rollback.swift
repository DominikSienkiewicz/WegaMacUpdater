import Foundation
import MacUpdaterCore

struct ForegroundCaskPreparation {
    let appPaths: [String: URL]
    let snapshots: [String: URL]
    let trustedCaskNames: [String]
    let publisherVetoes: [String: TeamIDAudit]
    /// LT-01 — the journaled operation this run's snapshots and verdicts belong to.
    let operation: UpdateOperationSession
}

enum ForegroundCaskPreparationResult {
    case ready(ForegroundCaskPreparation)
    case blocked(publisherVetoes: [String: TeamIDAudit])
}

// MARK: - Rollback net (casks)
//
// The snapshot -> canary -> rollback glue of `ScanStore`, split out of
// `ScanStore+Actions.swift` (file length) when LT-01 journaled the operation phases.
// Everything here feeds the one chain `CaskRollbackGuard` owns; the undo half lives in
// `ScanStore+Undo.swift`.
extension ScanStore {

    func prepareForegroundCasks(
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
        // LT-01 — the journal starts before the first snapshot: `planned` is what recovery
        // reads as "brew never ran here", and each confirmed clone advances to `snapshotted`.
        let operation = UpdateOperationStore.shared.begin(trigger: .manual)
        operation.recordPlanned(tokens: caskNames, appPaths: appPaths)
        let snapshots = snapshotCasks(caskNames, appPaths: appPaths, operation: operation)
        let missing = caskNames.filter { appPaths[$0] != nil && snapshots[$0] == nil }
        guard missing.isEmpty else {
            // Nothing mutated, so nothing here is worth the retention window: settle the
            // journal and drop the whole operation directory.
            operation.abortUnfinished()
            UpdateOperationStore.shared.removeOperation(id: operation.operation.id)
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
            publisherVetoes: publisherVetoes,
            operation: operation
        ))
    }

    func foregroundResourceDecision(
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

    // MARK: FEAT-05 (rollback) + FEAT-04 (watchdog Team ID)

    /// REL-03 — where the casks in this run keep their `.app` bundles, resolved at upgrade
    /// time and **returned** so the phases that need it are handed it explicitly.
    ///
    /// `caskIconPaths` is only ever filled by a full `runCheck`, so in the most ordinary
    /// session there is — launch, look at the restored list, press "Zaktualizuj wszystkie" —
    /// it was empty, `CaskRollbackGuard` cloned nothing and `verify` skipped every token.
    /// Whatever the last scan did resolve for these tokens is kept as a fallback: a
    /// `brew info` that cannot answer now must not take the net down with it.
    func resolveCaskAppPaths(_ tokens: [String]) async -> [String: URL] {
        guard let model, !tokens.isEmpty else { return [:] }
        let infos = (try? await model.brewService.caskInstallationInfo(tokens: tokens)) ?? []
        let resolved = dependencies.caskAppPathResolver.appPaths(from: infos)
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
    func snapshotCasks(
        _ tokens: [String],
        appPaths: [String: URL],
        operation: UpdateOperationSession
    ) -> [String: URL] {
        CaskRollbackGuard.snapshot(tokens: tokens, appPaths: appPaths, operation: operation)
    }

    /// Runs the canary/rollback chain and **returns** its verdicts, so they can join the
    /// run's per-item result. It used to only narrate into the collapsible log, which is how
    /// `.rollbackFailed` — the case that must never be silent — ended under a green banner.
    ///
    /// Takes the same `appPaths` the snapshot was made from: verifying against a second,
    /// separately obtained map is how `verify` came to skip the tokens it had just cloned.
    func postCaskUpgrade(
        _ tokens: [String],
        appPaths: [String: URL],
        snapshots: [String: URL],
        operation: UpdateOperationSession
    ) async -> [String: CaskValidationVerdict] {
        let verdicts = await CaskRollbackGuard.verify(
            tokens: tokens, appPaths: appPaths, snapshots: snapshots, operation: operation
        )
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

    /// M5 — works out which outdated casks the rollback net actually covers.
    ///
    /// A cask that installs no `.app` cannot be snapshotted, so `postCaskUpgrade` has always
    /// skipped it — silently, with no log line and no hint in the UI. The hole cannot be
    /// closed (there is nothing to clone), only disclosed: the row gets an honest "no
    /// protection" badge, and the log says so before the upgrade runs, not after.
    func resolveRollbackProtection() async {
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
}
