import Foundation
import MacUpdaterCore

/// The snapshot → canary → auto-rollback chain, in one place (F3).
///
/// It used to live inside `ScanStore.postCaskUpgrade`, reachable only from the window. The
/// background updater needs exactly the same guarantees — a bad upgrade must undo itself
/// whether or not anyone is watching — and a second copy of this logic is the one thing
/// that could quietly diverge from the first. So there is one copy, and both callers use it.
///
/// LT-01 — snapshots live in the calling operation's own unique directory and every phase
/// is journaled, so a crash mid-upgrade is recognizable (and recoverable) at the next
/// launch, and a healthy upgrade no longer deletes its snapshot: it is kept for the
/// retention window, which is what makes a manual "Cofnij aktualizację" possible at all.
/// A publisher mismatch preserves the original snapshot even after a successful
/// restoration; failed restoration also leaves it available for manual recovery.
@MainActor
enum CaskRollbackGuard {
    /// What happened to one cask after its upgrade.
    ///
    /// REL-02 moved the cases into Core as `CaskValidationVerdict` so they can travel into
    /// `UpdateRunOutcome` — the verdict is one phase of an item's result, not a private
    /// detail of this file, and until it reached the summary a failed rollback ended under
    /// a green banner.
    typealias Outcome = CaskValidationVerdict

    private enum PublisherBaseline {
        case ledger
        case expected(String?)
    }

    private enum BundleIdentityBaseline {
        case unchecked
        case expected(String?)
    }

    /// Reads the installed publishers before any snapshot or package-manager mutation.
    /// A bundle that already differs from the trusted ledger is not a safe rollback source,
    /// so callers must exclude every returned token from the upgrade command.
    static func publisherVetoes(tokens: [String], appPaths: [String: URL]) -> [String: TeamIDAudit] {
        var vetoes: [String: TeamIDAudit] = [:]
        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            let currentTeamID = CodeSignatureVerifier.teamID(ofAppAt: appURL)
            let audit = TeamIDLedger.shared.record(bundleID: TeamIDLedger.caskKey(token), teamID: currentTeamID)
            guard case let .changed(old, new) = audit else { continue }
            vetoes[token] = audit
            WegaLog.error(
                .homebrew,
                "\(token): aktualizacja zablokowana przed brew — zainstalowana aplikacja ma inny Team ID niż zaufany baseline (\(old) → \(new ?? "—"))."
            )
        }
        return vetoes
    }

    /// Copy-on-write clone (`clonefile`) of each cask's app bundle, keyed by token.
    /// Casks with no resolvable `.app` are skipped — see `RollbackProtection`, which is what
    /// tells the user so up front instead of leaving them silently unprotected.
    ///
    /// LT-01 — clones land in the operation's own `snapshots/` directory (never the
    /// predictable shared temp path) and each confirmed clone is journaled before the
    /// next one starts, so a crash here still leaves a complete record of what exists.
    static func snapshot(
        tokens: [String],
        appPaths: [String: URL],
        operation: UpdateOperationSession
    ) -> [String: URL] {
        var snapshots: [String: URL] = [:]
        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            let name = UpdateOperationSession.snapshotDirectoryName(for: token)
            let dest = operation.snapshotsDirectory.appendingPathComponent(name, isDirectory: true)
            if (try? BundleSnapshot.clone(appURL, to: dest)) != nil {
                snapshots[token] = dest
                operation.recordSnapshotted(token: token, snapshotName: name)
            }
        }
        return snapshots
    }

    /// Runs the Gatekeeper and publisher canaries, restoring the snapshot when either rejects
    /// the new bundle. Verdicts are journaled into the operation (`verified → committed`,
    /// or `rolledBack`); the snapshot itself is owned by the retention sweep.
    static func verify(
        tokens: [String],
        appPaths: [String: URL],
        snapshots: [String: URL],
        operation: UpdateOperationSession
    ) async -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]

        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            let outcome = await verify(
                token: token,
                snapshotURL: snapshots[token],
                validationURL: appURL,
                publisherBaseline: .ledger,
                bundleIdentityBaseline: .unchecked
            )
            // REL-07 — the decision matrix that produced this verdict also drives the durable
            // rolled-back mark: a restored build is remembered so `ManualUpdateScanner` can
            // force it back onto the list, a healthy one clears the mark.
            CaskRollbackLedger.shared.apply(token: token, verdict: outcome)
            // LT-01 — and the same verdict settles the item's journal phases.
            operation.recordVerdict(token: token, verdict: outcome)
            outcomes[token] = outcome
        }
        return outcomes
    }

    /// Verifies a replacement against the publisher read before mutation. The snapshot can
    /// originate in `~/Applications` while the installed artifact now lives in `/Applications`;
    /// validation and rollback therefore intentionally use `validationURL`, not the old path.
    static func verify(
        token: String,
        snapshotURL: URL,
        validationURL: URL,
        expectedTeamID: String?,
        expectedBundleIdentifier: String?,
        operation: UpdateOperationSession? = nil
    ) async -> Outcome {
        let outcome = await verify(
            token: token,
            snapshotURL: snapshotURL,
            validationURL: validationURL,
            publisherBaseline: .expected(expectedTeamID),
            bundleIdentityBaseline: .expected(expectedBundleIdentifier)
        )
        // REL-07 — the conscious "Aktualizuj przez Brew" retry lands here: a healthy result
        // clears the mark (the force-reinstall repaired the Caskroom metadata in the same pass),
        // while a fresh rollback re-arms it. Same ledger chokepoint as the batch canary.
        CaskRollbackLedger.shared.apply(token: token, verdict: outcome)
        operation?.recordVerdict(token: token, verdict: outcome)
        return outcome
    }

    private static func verify(
        token: String,
        snapshotURL: URL?,
        validationURL: URL,
        publisherBaseline: PublisherBaseline,
        bundleIdentityBaseline: BundleIdentityBaseline
    ) async -> Outcome {
        if case .expected(let expectedBundleIdentifier) = bundleIdentityBaseline {
            let installedBundleIdentifier = CaskReplacementArtifactIdentity.bundleIdentifier(
                at: validationURL
            )
            guard expectedBundleIdentifier == installedBundleIdentifier else {
                WegaLog.error(
                    .homebrew,
                    "\(token): identyfikator bundle zmienił się (\(expectedBundleIdentifier ?? "—") → \(installedBundleIdentifier ?? "—")); przywracam poprzednią wersję."
                )
                guard let snapshotURL else { return .rollbackFailed }
                return await restoreSnapshot(
                    snapshotURL,
                    to: validationURL,
                    preservingSnapshot: true
                )
                    ? .rolledBack
                    : .rollbackFailed
            }
        }

        let healthy = await Task.detached {
            CanaryCheck.passesGatekeeper(appAt: validationURL)
        }.value
        guard healthy else {
            guard let snapshotURL else { return .rollbackFailed }
            return await restoreSnapshot(snapshotURL, to: validationURL) ? .rolledBack : .rollbackFailed
        }

        let installedTeamID = await Task.detached {
            CodeSignatureVerifier.teamID(ofAppAt: validationURL)
        }.value
        let publisherAudit: TeamIDAudit
        switch publisherBaseline {
        case .ledger:
            publisherAudit = TeamIDLedger.shared.record(
                bundleID: TeamIDLedger.caskKey(token),
                teamID: installedTeamID
            )
        case .expected(let expectedTeamID):
            publisherAudit = expectedTeamID == installedTeamID
                ? .unchanged(teamID: installedTeamID)
                : .changed(old: expectedTeamID ?? "—", new: installedTeamID)
        }

        switch publisherAudit {
        case let .changed(old, new):
            WegaLog.error(
                .homebrew,
                "\(token): Team ID wydawcy zmienił się (\(old) → \(new ?? "—")); przywracam poprzednią wersję."
            )
            guard let snapshotURL else { return .rollbackFailed }
            return await restoreSnapshot(
                snapshotURL,
                to: validationURL,
                preservingSnapshot: true
            )
                ? .publisherChangedAndRolledBack(old: old, new: new)
                : .rollbackFailed
        case .firstSeen, .unchanged:
            if case .expected = publisherBaseline {
                TeamIDLedger.shared.record(bundleID: TeamIDLedger.caskKey(token), teamID: installedTeamID)
            }
            // LT-01 — the snapshot deliberately stays: it is the manual undo for the whole
            // retention window. It used to be deleted here, which is why "Cofnij
            // aktualizację" could not exist. `UpdateOperationStore.pruneExpired` owns it now.
            return .healthy
        }
    }

    /// Restores in place; falls back to the root helper when the destination is protected
    /// (`/Applications` owned by another user, SIP-adjacent locations). Internal (not
    /// private) so the crash-recovery and manual-undo paths restore through the exact same
    /// code as the canary.
    static func restoreSnapshot(
        _ snapshot: URL,
        to appURL: URL,
        preservingSnapshot: Bool = false
    ) async -> Bool {
        let restorationSource: URL
        if preservingSnapshot {
            restorationSource = snapshot.deletingLastPathComponent()
                .appendingPathComponent("restore-\(UUID().uuidString).app")
            do {
                try BundleSnapshot.clone(snapshot, to: restorationSource)
            } catch {
                WegaLog.error(.homebrew,
                              "Nie udało się zachować snapshotu przed rollbackiem: \(error.localizedDescription)")
                return false
            }
        } else {
            restorationSource = snapshot
        }
        defer {
            if preservingSnapshot {
                try? FileManager.default.removeItem(at: restorationSource)
            }
        }

        do {
            try BundleSnapshot.restore(snapshot: restorationSource, to: appURL)
            return true
        } catch {
            guard PrivilegedHelperClient.shared.isEnabled else { return false }
            do {
                try await PrivilegedHelperClient.shared.replaceBundle(
                    at: appURL.path, withSnapshotAt: restorationSource.path
                )
                return true
            } catch {
                WegaLog.error(.helper, "Rollback przez helper nie powiódł się: \(error.localizedDescription)")
                return false
            }
        }
    }
}

/// Guarantees that a foreground upgrade and a background upgrade never run at once (F3).
///
/// Both call `brew upgrade --cask` and both take snapshots; overlapping them would let one
/// restore a bundle the other is mid-way through replacing. The window always wins — a user
/// waiting on a click must not be told to wait for a timer.
@MainActor
final class UpgradeMutex {
    static let shared = UpgradeMutex()

    private(set) var isBusy = false

    private init() {}

    /// Returns `false` when an upgrade is already in flight; the caller must then do nothing.
    func acquire() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    func release() {
        isBusy = false
    }
}
