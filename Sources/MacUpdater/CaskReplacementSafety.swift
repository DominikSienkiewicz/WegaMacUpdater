import Foundation
import MacUpdaterCore

/// Safety transaction for UI flows that adopt an existing app with
/// `brew install --cask --force`.
@MainActor
enum CaskReplacementSafety {
    struct Preparation {
        let token: String
        let appURL: URL
        let snapshotURL: URL
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
        return .ready(Preparation(token: token, appURL: appURL, snapshotURL: snapshotURL))
    }

    static func verify(_ preparation: Preparation) async -> CaskValidationVerdict {
        let verdicts = await CaskRollbackGuard.verify(
            tokens: [preparation.token],
            appPaths: [preparation.token: preparation.appURL],
            snapshots: [preparation.token: preparation.snapshotURL]
        )
        return verdicts[preparation.token] ?? .rollbackFailed
    }
}
