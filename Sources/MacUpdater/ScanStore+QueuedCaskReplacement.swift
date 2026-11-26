import Foundation
import MacUpdaterCore

extension ScanStore {
    func runQueuedCaskReplacements(_ replacements: [QueuedCaskReplacement]) async -> [LaneItemResult] {
        var results: [LaneItemResult] = []
        for replacement in replacements {
            if let result = await replaceQueuedCask(replacement) { results.append(result) }
        }
        return results
    }

    private func replaceQueuedCask(_ replacement: QueuedCaskReplacement) async -> LaneItemResult? {
        let item = replacement.item
        guard !skipQueuedReplacement(item.key) else { return nil }
        let token = replacement.token
        guard let brew = model?.brewService,
              queueableCaskReplacements(for: .all).contains(replacement),
              let profiles = try? await brew.caskArtifactProfiles(tokens: [token]),
              let profile = profiles.first(where: { $0.token == token }),
              replacement.isSupported(profile),
              replacement.hasExactDestination(),
              let catalogVersion = await brew.caskLatestVersion(token: token),
              catalogVersion == replacement.app.availableVersion
                || versionVariants(catalogVersion).first == replacement.app.availableVersion,
              let recordedVersions = try? await brew.caskInstalledVersions(),
              replacement.ownsInstallation == (recordedVersions[token] != nil),
              replacement.matchesOnDisk() else {
            return queuedReplacementFailure(item: item, reason: tr("Oferta lub instalacja aplikacji zmieniła się. Sprawdź aktualizacje ponownie."))
        }
        guard !skipQueuedReplacement(item.key) else { return nil }
        if profile.mayRequireAdminPassword, holdsPasswordPrompt(for: item) { return nil }

        let preparation: CaskReplacementSafety.Preparation
        switch await CaskReplacementSafety.prepare(
            token: token, appURL: replacement.app.path, brewService: brew, expectedVersion: catalogVersion
        ) {
        case .ready(let ready):
            preparation = ready
        case .publisherRejected(let old, let new):
            markRunRow(item.key, .failed)
            return LaneItemResult(item: item, outcome: nil, publisherVeto: .changed(old: old, new: new))
        case .resourcePostponed(let reason):
            var result = queuedReplacementFailure(item: item, reason: reason.localizedMessage)
            result.postponeReason = reason
            return result
        case .journalUnavailable(let reason):
            return queuedReplacementFailure(item: item, reason: reason)
        case .snapshotFailed, .caskInstallsNoApp:
            return queuedReplacementFailure(item: item, reason: tr("Nie udało się zrobić kopii zapasowej przed aktualizacją. Sprawdź wolne miejsce na dysku i spróbuj ponownie."))
        }

        guard !skipQueuedReplacement(item.key) else {
            cancelQueuedPreparation(preparation)
            return nil
        }
        guard !profile.mayRequireAdminPassword || !holdsPasswordPrompt(for: item) else {
            cancelQueuedPreparation(preparation)
            return nil
        }
        guard queueableCaskReplacements(for: .all).contains(replacement),
              replacement.hasExactDestination(), replacement.matchesOnDisk() else {
            cancelQueuedPreparation(preparation)
            return queuedReplacementFailure(item: item, reason: tr("Oferta lub instalacja aplikacji zmieniła się. Sprawdź aktualizacje ponownie."))
        }
        return await runQueuedReplacement(replacement, preparation: preparation, catalogVersion: catalogVersion,
                                          recordedVersion: recordedVersions[token], brew: brew)
    }

    private func runQueuedReplacement(
        _ replacement: QueuedCaskReplacement,
        preparation: CaskReplacementSafety.Preparation,
        catalogVersion: String, recordedVersion: String?, brew: BrewService
    ) async -> LaneItemResult {
        let item = replacement.item
        let token = replacement.token
        preparation.operation.recordInstalling()
        do { try preparation.operation.requirePersisted() }
        catch { return queuedReplacementFailure(item: item, reason: error.localizedDescription) }
        UpdateStageDiagnostics.recordOperation(preparation.operation)

        markRunRow(item.key, .installing)
        beginItem(named: token)
        defer { endItem() }
        let arguments = replacement.arguments(catalogVersion: catalogVersion, recordedVersion: recordedVersion)
        let outcome = await runBrewUpgrade(arguments: arguments, logSource: token, streamsProgress: false)
        markRunRow(item.key, outcome.isSuccessful ? .installedChecking : .failed)
        let installedURL = await CaskReplacementSafety.resolveInstalledAppURL(preparation, brewService: brew)
        let verifiedURL = installedURL.flatMap {
            InstallationIdentity(path: $0) == InstallationIdentity(path: replacement.app.path) ? $0 : nil
        }
        let verdict = await CaskReplacementSafety.verify(preparation, installedAppURL: verifiedURL)
        if verdict.failsTheRunRow { markRunRow(item.key, .failed) }
        if outcome.isSuccessful, !verdict.failsTheRunRow { creditUnit() }
        return LaneItemResult(item: item, outcome: outcome, validation: verdict,
                              operationID: preparation.operation.operation.id)
    }

    private func skipQueuedReplacement(_ key: String) -> Bool {
        guard shouldStopUpdate(before: [key]) else { return false }
        markRunRow(key, .notStarted)
        return true
    }

    private func cancelQueuedPreparation(_ preparation: CaskReplacementSafety.Preparation) {
        preparation.operation.abortUnfinished()
        UpdateOperationStore.shared.removeOperation(id: preparation.operation.operation.id)
    }

    private func queuedReplacementFailure(item: OutdatedItem, reason: String) -> LaneItemResult {
        markRunRow(item.key, .failed)
        brewLog.append(UpgradeLogPrefix.line("⚠ " + reason, from: item.name))
        return LaneItemResult(item: item, outcome: BrewUpgradeOutcome(
            exitCode: -1, failedTokens: [item.name], errorLines: [reason]
        ))
    }

    func finishReplacementSelection(_ rows: [LaneItemResult]) {
        let blocked = rows.filter { $0.postponeReason?.diskShortfall != nil }
        selected.formIntersection(blocked.map(\.item.key))
        guard !selected.isEmpty else { return }
        restrictSelection(to: .all)
        let reasons = blocked.filter { selected.contains($0.item.key) }.compactMap(\.postponeReason)
        guard let worst = reasons.max(by: { ($0.diskShortfall ?? 0) < ($1.diskShortfall ?? 0) }) else { return }
        showStickyBanner(BannerData(variant: .danger, title: tr("Odkładam pobieranie"),
                                    message: worst.localizedMessage, action: .openCleanup))
    }
}
