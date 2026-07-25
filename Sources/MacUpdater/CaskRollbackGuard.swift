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
/// Failed restoration keeps the snapshot for manual recovery; successful restoration consumes
/// it while atomically putting the old bundle back in place.
@MainActor
enum CaskRollbackGuard {
    /// What happened to one cask after its upgrade.
    ///
    /// REL-02 moved the cases into Core as `CaskValidationVerdict` so they can travel into
    /// `UpdateRunOutcome` — the verdict is one phase of an item's result, not a private
    /// detail of this file, and until it reached the summary a failed rollback ended under
    /// a green banner.
    typealias Outcome = CaskValidationVerdict

    /// Copy-on-write clone (`clonefile`) of each cask's app bundle, keyed by token.
    /// Casks with no resolvable `.app` are skipped — see `RollbackProtection`, which is what
    /// tells the user so up front instead of leaving them silently unprotected.
    static func snapshot(tokens: [String], appPaths: [String: URL]) -> [String: URL] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wega-rollback", isDirectory: true)
        var snapshots: [String: URL] = [:]
        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            // This is the last read of the installed app before brew can mutate it. Seeding
            // from the post-upgrade bundle would make a first publisher swap look trusted.
            let oldTeamID = CodeSignatureVerifier.teamID(ofAppAt: appURL)
            let dest = base.appendingPathComponent("\(token).app")
            if (try? BundleSnapshot.clone(appURL, to: dest)) != nil {
                snapshots[token] = dest
                if case let .changed(old, new) = TeamIDLedger.shared.record(
                    bundleID: "cask:\(token)", teamID: oldTeamID
                ) {
                    WegaLog.error(
                        .homebrew,
                        "\(token): zainstalowana aplikacja ma inny Team ID niż zaufany baseline (\(old) → \(new ?? "—"))."
                    )
                }
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
            let healthy = await Task.detached { CanaryCheck.passesGatekeeper(appAt: appURL) }.value

            if !healthy, let snapshot = snapshots[token] {
                outcomes[token] = await restore(snapshot: snapshot, to: appURL) ? .rolledBack : .rollbackFailed
            } else if !healthy {
                // Nothing to restore from: the cask installs no app bundle we could clone.
                outcomes[token] = .rollbackFailed
            } else {
                let teamID = await Task.detached { CodeSignatureVerifier.teamID(ofAppAt: appURL) }.value
                switch TeamIDLedger.shared.record(bundleID: "cask:\(token)", teamID: teamID) {
                case let .changed(old, new):
                    WegaLog.error(
                        .homebrew,
                        "\(token): Team ID wydawcy zmienił się (\(old) → \(new ?? "—")); przywracam poprzednią wersję."
                    )
                    guard let snapshot = snapshots[token] else {
                        outcomes[token] = .rollbackFailed
                        continue
                    }
                    outcomes[token] = await restore(
                        snapshot: snapshot, to: appURL, preservingSnapshot: true
                    )
                        ? .publisherChangedAndRolledBack(old: old, new: new)
                        : .rollbackFailed
                case .firstSeen, .unchanged:
                    outcomes[token] = .healthy
                    if let snapshot = snapshots[token] {
                        try? FileManager.default.removeItem(at: snapshot)
                    }
                }
            }
        }
        return outcomes
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
