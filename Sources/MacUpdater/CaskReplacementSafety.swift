import Foundation
import MacUpdaterCore

/// Safety transaction for UI flows that adopt an existing app with
/// `brew install --cask --force`.
@MainActor
enum CaskReplacementSafety {
    struct Preparation {
        let token: String
        let snapshotURL: URL
        let expectedTeamID: String?
        let identity: CaskReplacementArtifactIdentity
        /// LT-01 — the journaled operation this adoption runs inside; the caller marks
        /// `installing` before invoking brew.
        let operation: UpdateOperationSession
    }

    enum PreparationResult {
        case ready(Preparation)
        case resourcePostponed(String)
        case publisherRejected(old: String, new: String?)
        case snapshotFailed
    }

    static func prepare(
        token: String,
        appURL: URL,
        brewService: BrewService
    ) async -> PreparationResult {
        let downloads: [CaskDownloadInfo]
        do {
            downloads = try await brewService.caskDownloadInfo(tokens: [token])
        } catch {
            downloads = []
            WegaLog.error(.homebrew, "\(token): dane pobierania niedostępne — \(error.localizedDescription)")
        }
        let downloadsByToken = Dictionary(
            downloads.map { ($0.token, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let downloadSizes = await DownloadResourcePreflight.probe(
            tokens: [token],
            downloads: downloadsByToken
        )
        let appPaths = [token: appURL]
        let resourceDecision = await DownloadResourcePreflight.decision(
            tokens: [token],
            downloadSizes: downloadSizes,
            appPaths: appPaths
        )
        guard case .allow = resourceDecision else {
            guard case .postpone(let reason) = resourceDecision else {
                return .resourcePostponed("nieznany powód")
            }
            return .resourcePostponed(reason)
        }

        let installedTeamID = await Task.detached {
            CodeSignatureVerifier.teamID(ofAppAt: appURL)
        }.value
        let bundleID = CaskReplacementArtifactIdentity.bundleIdentifier(at: appURL)
        let ledger = TeamIDLedger.shared
        let publisherAudit = TeamIDLedger.classifyCask(
            storedByBundleID: bundleID.flatMap { ledger.teamID(forBundleID: $0) },
            storedByCaskKey: ledger.teamID(forBundleID: TeamIDLedger.caskKey(token)),
            new: installedTeamID
        )
        if case let .changed(old, new) = publisherAudit {
            return .publisherRejected(old: old, new: new)
        }
        if let bundleID {
            ledger.record(bundleID: bundleID, teamID: installedTeamID)
        }

        // LT-01 — the adoption runs inside a journaled operation too: its snapshot lives
        // in the operation's own directory and a crash mid-`brew install --force` is
        // recoverable, exactly like a batch upgrade.
        let operation = UpdateOperationStore.shared.begin(trigger: .adoption)
        operation.recordPlanned(tokens: [token], appPaths: appPaths)
        let snapshots = CaskRollbackGuard.snapshot(tokens: [token], appPaths: appPaths, operation: operation)
        guard let snapshotURL = snapshots[token] else {
            operation.abortUnfinished()
            UpdateOperationStore.shared.removeOperation(id: operation.operation.id)
            return .snapshotFailed
        }
        return .ready(Preparation(
            token: token,
            snapshotURL: snapshotURL,
            expectedTeamID: installedTeamID,
            identity: CaskReplacementArtifactIdentity(
                bundleIdentifier: bundleID,
                appURL: appURL
            ),
            operation: operation
        ))
    }

    static func resolveInstalledAppURL(
        _ preparation: Preparation,
        brewService: BrewService
    ) async -> URL? {
        let token = preparation.token
        do {
            let caskInstallationInfo = try await brewService.caskInstallationInfo(tokens: [token])
            guard let artifact = preparation.identity.matchingArtifact(
                token: token,
                in: caskInstallationInfo
            ) else {
                WegaLog.error(
                    .homebrew,
                    "\(token): brak jednoznacznego artefaktu aplikacji po instalacji."
                )
                return nil
            }
            switch CaskReplacementArtifactLocationResolver().resolve(artifact: artifact) {
            case .resolved(let appURL):
                let installationInfo = [
                    BrewCaskInstallationInfo(token: token, appArtifacts: [artifact])
                ]
                guard CaskAppPathResolver().appPaths(from: installationInfo)[token] == appURL else {
                    WegaLog.error(
                        .homebrew,
                        "\(token): lokalizacja artefaktu \(artifact) zmieniła się podczas weryfikacji."
                    )
                    return nil
                }
                return appURL
            case .unresolved:
                WegaLog.error(
                    .homebrew,
                    "\(token): artefakt \(artifact) nie istnieje po instalacji."
                )
                return nil
            case .ambiguous:
                WegaLog.error(
                    .homebrew,
                    "\(token): artefakt \(artifact) istnieje w /Applications i ~/Applications."
                )
                return nil
            }
        } catch {
            WegaLog.error(
                .homebrew,
                "\(token): nie udało się ustalić ścieżki aplikacji po instalacji — \(error.localizedDescription)"
            )
            return nil
        }
    }

    static func verify(
        _ preparation: Preparation,
        installedAppURL: URL?
    ) async -> CaskValidationVerdict {
        guard let installedAppURL else { return .rollbackFailed }
        return await CaskRollbackGuard.verify(
            token: preparation.token,
            snapshotURL: preparation.snapshotURL,
            validationURL: installedAppURL,
            expectedTeamID: preparation.expectedTeamID,
            expectedBundleIdentifier: preparation.identity.bundleIdentifier,
            operation: preparation.operation
        )
    }
}
