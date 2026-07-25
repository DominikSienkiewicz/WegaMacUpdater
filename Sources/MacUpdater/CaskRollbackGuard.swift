import Foundation
import MacUpdaterCore

/// The snapshot → canary → auto-rollback chain, in one place (F3).
///
/// It used to live inside `ScanStore.postCaskUpgrade`, reachable only from the window. The
/// background updater needs exactly the same guarantees — a bad upgrade must undo itself
/// whether or not anyone is watching — and a second copy of this logic is the one thing
/// that could quietly diverge from the first. So there is one copy, and both callers use it.
///
/// A healthy upgrade consumes no rollback storage: its snapshot is deleted after all checks.
/// A publisher mismatch preserves the original snapshot even after a successful restoration;
/// failed restoration also leaves it available for manual recovery.
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

    /// Reads the installed publishers before any snapshot or package-manager mutation.
    /// A bundle that already differs from the trusted ledger is not a safe rollback source,
    /// so callers must exclude every returned token from the upgrade command.
    static func publisherVetoes(tokens: [String], appPaths: [String: URL]) -> [String: TeamIDAudit] {
        var vetoes: [String: TeamIDAudit] = [:]
        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            let currentTeamID = CodeSignatureVerifier.teamID(ofAppAt: appURL)
            let audit = TeamIDLedger.shared.record(bundleID: "cask:\(token)", teamID: currentTeamID)
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
    static func snapshot(tokens: [String], appPaths: [String: URL]) -> [String: URL] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wega-rollback", isDirectory: true)
        var snapshots: [String: URL] = [:]
        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            let dest = base.appendingPathComponent("\(token).app")
            if (try? BundleSnapshot.clone(appURL, to: dest)) != nil {
                snapshots[token] = dest
            }
        }
        return snapshots
    }

    /// Runs the Gatekeeper and publisher canaries, restoring the snapshot when either rejects
    /// the new bundle. Only a fully healthy upgrade deletes its snapshot.
    static func verify(tokens: [String], appPaths: [String: URL], snapshots: [String: URL]) async -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]

        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            outcomes[token] = await verify(
                token: token,
                snapshotURL: snapshots[token],
                validationURL: appURL,
                publisherBaseline: .ledger
            )
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
        expectedTeamID: String?
    ) async -> Outcome {
        await verify(
            token: token,
            snapshotURL: snapshotURL,
            validationURL: validationURL,
            publisherBaseline: .expected(expectedTeamID)
        )
    }

    private static func verify(
        token: String,
        snapshotURL: URL?,
        validationURL: URL,
        publisherBaseline: PublisherBaseline
    ) async -> Outcome {
        let healthy = await Task.detached {
            CanaryCheck.passesGatekeeper(appAt: validationURL)
        }.value
        guard healthy else {
            guard let snapshotURL else { return .rollbackFailed }
            return await restore(snapshot: snapshotURL, to: validationURL) ? .rolledBack : .rollbackFailed
        }

        let installedTeamID = await Task.detached {
            CodeSignatureVerifier.teamID(ofAppAt: validationURL)
        }.value
        let publisherAudit: TeamIDAudit
        switch publisherBaseline {
        case .ledger:
            publisherAudit = TeamIDLedger.shared.record(
                bundleID: "cask:\(token)",
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
            return await restore(
                snapshot: snapshotURL,
                to: validationURL,
                preservingSnapshot: true
            )
                ? .publisherChangedAndRolledBack(old: old, new: new)
                : .rollbackFailed
        case .firstSeen, .unchanged:
            if case .expected = publisherBaseline {
                TeamIDLedger.shared.record(bundleID: "cask:\(token)", teamID: installedTeamID)
            }
            if let snapshotURL {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            return .healthy
        }
    }

    /// Restores in place; falls back to the root helper when the destination is protected
    /// (`/Applications` owned by another user, SIP-adjacent locations).
    private static func restore(
        snapshot: URL,
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
