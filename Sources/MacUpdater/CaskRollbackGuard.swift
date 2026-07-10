import Foundation
import MacUpdaterCore

/// The snapshot → canary → auto-rollback chain, in one place (F3).
///
/// It used to live inside `ScanStore.postCaskUpgrade`, reachable only from the window. The
/// background updater needs exactly the same guarantees — a bad upgrade must undo itself
/// whether or not anyone is watching — and a second copy of this logic is the one thing
/// that could quietly diverge from the first. So there is one copy, and both callers use it.
///
/// What it does not do: keep the snapshot. It is deleted as soon as the canary has run, so
/// this offers automatic recovery from a bad upgrade, never a manual "Undo" afterwards.
@MainActor
enum CaskRollbackGuard {
    /// What happened to one cask after its upgrade.
    enum Outcome: Equatable {
        /// Gatekeeper accepted the new version.
        case healthy
        /// The new version failed its check and the previous one was restored.
        case rolledBack
        /// The new version failed its check and could not be restored. The worst case, and
        /// the one that must never be silent.
        case rollbackFailed
        /// The publisher's Team ID changed between versions — a possible takeover.
        case publisherChanged(old: String, new: String?)
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
            if (try? BundleSnapshot.clone(appURL, to: dest)) != nil { snapshots[token] = dest }
        }
        return snapshots
    }

    /// Runs the Gatekeeper canary, restores the snapshot on failure, records the publisher's
    /// Team ID on success, and cleans up. Returns one outcome per cask that had an app path.
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
                if case let .changed(old, new) = TeamIDLedger.shared.record(bundleID: "cask:\(token)", teamID: teamID) {
                    outcomes[token] = .publisherChanged(old: old, new: new)
                } else {
                    outcomes[token] = .healthy
                }
            }

            if let snapshot = snapshots[token] { try? FileManager.default.removeItem(at: snapshot) }
        }
        return outcomes
    }

    /// Restores in place; falls back to the root helper when the destination is protected
    /// (`/Applications` owned by another user, SIP-adjacent locations).
    private static func restore(snapshot: URL, to appURL: URL) async -> Bool {
        do {
            try BundleSnapshot.restore(snapshot: snapshot, to: appURL)
            return true
        } catch {
            guard PrivilegedHelperClient.shared.isEnabled else { return false }
            do {
                try await PrivilegedHelperClient.shared.replaceBundle(at: appURL.path, withSnapshotAt: snapshot.path)
                return true
            } catch {
                AppLogger.app.error("Rollback przez helper nie powiódł się: \(error.localizedDescription, privacy: .public)")
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
