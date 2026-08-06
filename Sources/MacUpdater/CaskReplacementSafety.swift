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
        /// The cask installs no `.app`, so there is nothing to adopt, snapshot or verify.
        case caskInstallsNoApp
    }

    /// Whether adopting this token could not possibly work, according to Homebrew's own
    /// metadata: the cask declares no `app` artifact at all.
    ///
    /// `zoom` and `google-drive` are `pkg` casks. Adoption used to run
    /// `brew install --cask --force` on them regardless, then look for an app artifact that
    /// does not exist; `resolveInstalledAppURL` returned `nil` and `verify` translated that
    /// `nil` into `.rollbackFailed` — the enum's loudest case, reserved for a broken upgrade
    /// that could not be undone. The user was told their app might be unusable when in truth
    /// nothing had been verified and nothing restored.
    ///
    /// The batch upgrade path has always asked this question through ``RollbackProtection``;
    /// this is the same question, asked by the path that skipped it. Answering it before brew
    /// runs also avoids reinstalling an app that was already current.
    ///
    /// An unknown profile (brew unreachable, token absent) is deliberately **not** a refusal:
    /// the gate exists to replace a misleading verdict, not to add a new way to fail, and the
    /// post-install resolution still fails closed.
    static func adoptionIsPointless(token: String, profiles: [CaskArtifactProfile]) -> Bool {
        guard let profile = profiles.first(where: { $0.token == token }) else { return false }
        return RollbackProtection.evaluate(profile: profile) != .protected
    }

    static func prepare(
        token: String,
        appURL: URL,
        brewService: BrewService
    ) async -> PreparationResult {
        // First, and before anything with a side effect: a cask that installs no app can
        // neither be snapshotted nor verified, and running brew on it only wastes a
        // reinstall on the way to a verdict that would misdescribe the outcome.
        if let profiles = try? await brewService.caskArtifactProfiles(tokens: [token]),
           adoptionIsPointless(token: token, profiles: profiles) {
            WegaLog.error(
                .homebrew,
                "\(token): cask nie instaluje aplikacji (.app) — nie da się go przejąć ani zabezpieczyć rollbackiem."
            )
            return .caskInstallsNoApp
        }

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
        brewService: BrewService,
        locationResolver: CaskReplacementArtifactLocationResolver? = nil,
        appPathResolver: CaskAppPathResolver? = nil
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
            let location = if let locationResolver {
                locationResolver.resolve(artifact: artifact)
            } else {
                CaskReplacementArtifactLocationResolver().resolve(artifact: artifact)
            }
            switch location {
            case .resolved(let appURL):
                let installationInfo = [
                    BrewCaskInstallationInfo(token: token, appArtifacts: [artifact])
                ]
                let canonicalAppURL = if let appPathResolver {
                    appPathResolver.appPaths(from: installationInfo)[token]
                } else {
                    CaskAppPathResolver().appPaths(from: installationInfo)[token]
                }
                guard canonicalAppURL == appURL else {
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
