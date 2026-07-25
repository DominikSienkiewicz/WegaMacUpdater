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
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        let ledger = TeamIDLedger.shared
        let publisherAudit = TeamIDLedger.classifyCask(
            storedByBundleID: bundleID.flatMap { ledger.teamID(forBundleID: $0) },
            storedByCaskKey: ledger.teamID(forBundleID: "cask:\(token)"),
            new: installedTeamID
        )
        if case let .changed(old, new) = publisherAudit {
            return .publisherRejected(old: old, new: new)
        }
        if let bundleID {
            ledger.record(bundleID: bundleID, teamID: installedTeamID)
        }

        let snapshots = CaskRollbackGuard.snapshot(tokens: [token], appPaths: appPaths)
        guard let snapshotURL = snapshots[token] else { return .snapshotFailed }
        return .ready(Preparation(
            token: token,
            snapshotURL: snapshotURL,
            expectedTeamID: installedTeamID
        ))
    }

    static func resolveInstalledAppURL(token: String, brewService: BrewService) async -> URL? {
        do {
            let installationInfo = try await brewService.caskInstallationInfo(tokens: [token])
            return CaskAppPathResolver().appPaths(from: installationInfo)[token]
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
            expectedTeamID: preparation.expectedTeamID
        )
    }
}
