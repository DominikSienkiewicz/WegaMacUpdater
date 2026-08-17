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

    struct Dependencies: Sendable {
        var teamIDBeforeMutation: @Sendable (URL) -> String?
        var teamIDAfterMutation: @Sendable (URL) async -> String?
        var recordTeamID: @Sendable (String, String?) -> TeamIDAudit
        var applyRollbackLedger: @MainActor @Sendable (String, Outcome) -> Void
        var clone: @Sendable (URL, URL) throws -> Void
        var bundleIdentifier: @Sendable (URL) -> String?
        var passesGatekeeper: @Sendable (URL) async -> Bool
        var restore: @Sendable (URL, URL) throws -> Void
        var helperIsEnabled: @MainActor @Sendable () -> Bool
        var helperReplace: @MainActor @Sendable (String, String) async throws -> Void
        var removeItem: @Sendable (URL) throws -> Void
        var smokeTestIsEnabled: @Sendable () -> Bool
        var launchSmokeTest: @Sendable (URL) async -> LaunchSmokeTest.Verdict

        static let live = Dependencies(
            teamIDBeforeMutation: { CodeSignatureVerifier.teamID(ofAppAt: $0) },
            teamIDAfterMutation: { appURL in
                await Task.detached {
                    CodeSignatureVerifier.teamID(ofAppAt: appURL)
                }.value
            },
            recordTeamID: { TeamIDLedger.shared.record(bundleID: $0, teamID: $1) },
            applyRollbackLedger: { CaskRollbackLedger.shared.apply(token: $0, verdict: $1) },
            clone: { try BundleSnapshot.clone($0, to: $1) },
            bundleIdentifier: { CaskReplacementArtifactIdentity.bundleIdentifier(at: $0) },
            passesGatekeeper: { appURL in
                await Task.detached {
                    CanaryCheck.passesGatekeeper(appAt: appURL)
                }.value
            },
            restore: { try BundleSnapshot.restore(snapshot: $0, to: $1) },
            helperIsEnabled: { PrivilegedHelperClient.shared.isEnabled },
            helperReplace: {
                try await PrivilegedHelperClient.shared.replaceBundle(
                    at: $0,
                    withSnapshotAt: $1
                )
            },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            smokeTestIsEnabled: { LaunchSmokeTestConfiguration.isEnabled() },
            launchSmokeTest: {
                await LaunchSmokeTest.run(bundleAt: $0, probe: WorkspaceAppLaunchProbe())
            }
        )
    }

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
    static func publisherVetoes(
        tokens: [String],
        appPaths: [String: URL]
    ) -> [String: TeamIDAudit] {
        publisherVetoesImpl(tokens: tokens, appPaths: appPaths, dependencies: nil)
    }

    static func publisherVetoes(
        tokens: [String],
        appPaths: [String: URL],
        dependencies: Dependencies
    ) -> [String: TeamIDAudit] {
        publisherVetoesImpl(tokens: tokens, appPaths: appPaths, dependencies: dependencies)
    }

    private static func publisherVetoesImpl(
        tokens: [String],
        appPaths: [String: URL],
        dependencies: Dependencies?
    ) -> [String: TeamIDAudit] {
        var vetoes: [String: TeamIDAudit] = [:]
        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            let currentTeamID: String?
            if let dependencies {
                currentTeamID = dependencies.teamIDBeforeMutation(appURL)
            } else {
                currentTeamID = CodeSignatureVerifier.teamID(ofAppAt: appURL)
            }
            let audit = dependencies?.recordTeamID(TeamIDLedger.caskKey(token), currentTeamID)
                ?? TeamIDLedger.shared.record(
                    bundleID: TeamIDLedger.caskKey(token),
                    teamID: currentTeamID
                )
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
        snapshotImpl(tokens: tokens, appPaths: appPaths, operation: operation, dependencies: nil)
    }

    static func snapshot(
        tokens: [String],
        appPaths: [String: URL],
        operation: UpdateOperationSession,
        dependencies: Dependencies
    ) -> [String: URL] {
        snapshotImpl(tokens: tokens, appPaths: appPaths, operation: operation, dependencies: dependencies)
    }

    private static func snapshotImpl(
        tokens: [String],
        appPaths: [String: URL],
        operation: UpdateOperationSession,
        dependencies: Dependencies?
    ) -> [String: URL] {
        var snapshots: [String: URL] = [:]
        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            let name = UpdateOperationSession.snapshotDirectoryName(for: token)
            let dest = operation.snapshotsDirectory.appendingPathComponent(name, isDirectory: true)
            let cloned = if let dependencies {
                (try? dependencies.clone(appURL, dest)) != nil
            } else {
                (try? BundleSnapshot.clone(appURL, to: dest)) != nil
            }
            if cloned {
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

    static func verify(
        tokens: [String],
        appPaths: [String: URL],
        snapshots: [String: URL],
        operation: UpdateOperationSession,
        dependencies: Dependencies
    ) async -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]
        for token in tokens {
            guard let appURL = appPaths[token] else { continue }
            let outcome = await verify(
                token: token,
                snapshotURL: snapshots[token],
                validationURL: appURL,
                publisherBaseline: .ledger,
                bundleIdentityBaseline: .unchecked,
                dependencies: dependencies
            )
            dependencies.applyRollbackLedger(token, outcome)
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

    static func verify(
        token: String,
        snapshotURL: URL,
        validationURL: URL,
        expectedTeamID: String?,
        expectedBundleIdentifier: String?,
        operation: UpdateOperationSession? = nil,
        dependencies: Dependencies = .live
    ) async -> Outcome {
        let outcome = await verify(
            token: token,
            snapshotURL: snapshotURL,
            validationURL: validationURL,
            publisherBaseline: .expected(expectedTeamID),
            bundleIdentityBaseline: .expected(expectedBundleIdentifier),
            dependencies: dependencies
        )
        dependencies.applyRollbackLedger(token, outcome)
        operation?.recordVerdict(token: token, verdict: outcome)
        return outcome
    }

    private static func verify(
        token: String,
        snapshotURL: URL?,
        validationURL: URL,
        publisherBaseline: PublisherBaseline,
        bundleIdentityBaseline: BundleIdentityBaseline,
        dependencies: Dependencies? = nil
    ) async -> Outcome {
        func restoreSnapshot(
            _ snapshot: URL,
            to appURL: URL,
            preservingSnapshot: Bool = false
        ) async -> Bool {
            await Self.restoreSnapshot(
                snapshot,
                to: appURL,
                preservingSnapshot: preservingSnapshot,
                dependencies: dependencies
            )
        }
        func launchSmokeTest(token: String, appURL: URL) async -> LaunchSmokeTest.Verdict {
            await Self.launchSmokeTest(
                token: token,
                appURL: appURL,
                dependencies: dependencies
            )
        }

        if case .expected(let expectedBundleIdentifier) = bundleIdentityBaseline {
            let installedBundleIdentifier: String?
            if let dependencies {
                installedBundleIdentifier = dependencies.bundleIdentifier(validationURL)
            } else {
                installedBundleIdentifier = CaskReplacementArtifactIdentity.bundleIdentifier(at: validationURL)
            }
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

        func liveGatekeeperResult() async -> Bool {
            let healthy = await Task.detached {
                CanaryCheck.passesGatekeeper(appAt: validationURL)
            }.value
            return healthy
        }
        let healthy = if let dependencies {
            await dependencies.passesGatekeeper(validationURL)
        } else {
            await liveGatekeeperResult()
        }
        guard healthy else {
            guard let snapshotURL else { return .rollbackFailed }
            return await restoreSnapshot(snapshotURL, to: validationURL) ? .rolledBack : .rollbackFailed
        }

        func liveInstalledTeamID() async -> String? {
            let installedTeamID = await Task.detached {
                CodeSignatureVerifier.teamID(ofAppAt: validationURL)
            }.value
            return installedTeamID
        }
        let installedTeamID = if let dependencies {
            await dependencies.teamIDAfterMutation(validationURL)
        } else {
            await liveInstalledTeamID()
        }
        let publisherAudit: TeamIDAudit
        switch publisherBaseline {
        case .ledger:
            if let dependencies {
                publisherAudit = dependencies.recordTeamID(TeamIDLedger.caskKey(token), installedTeamID)
            } else {
                publisherAudit = TeamIDLedger.shared.record(
                    bundleID: TeamIDLedger.caskKey(token),
                    teamID: installedTeamID
                )
            }
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
                if let dependencies {
                    _ = dependencies.recordTeamID(TeamIDLedger.caskKey(token), installedTeamID)
                } else {
                    TeamIDLedger.shared.record(bundleID: TeamIDLedger.caskKey(token), teamID: installedTeamID)
                }
            }
            // LT-02 — the fourth and last gate: everything above describes the artifact, this
            // one describes what happens when it runs. It comes last on purpose — a bundle
            // whose identity or publisher is in doubt is the last thing that should be
            // executed, so the smoke test only ever starts a build the other three approved.
            guard let snapshotURL else { return .healthy }

            // Before any gate describing the artifact: did an artifact actually arrive? brew
            // exits 0 without touching the disk whenever its Caskroom record already names the
            // version the cask offers, and the confirming rescan cannot catch that because it
            // asks brew — the very thing whose record is wrong. The snapshot is the pre-upgrade
            // bundle, so the disk answers it directly. Without this the canary would inspect the
            // *old* app, pass it, and talk a no-op up into "zaktualizowano" (Obsidian 1.13.6,
            // reported updated twice while never moving — see `NoOpCaskUpgradeTests`).
            if !UpdateOperationRecoveryPlan.bundleWasReplaced(
                installedVersion: UpdateOperationRecoveryPlan.bundleShortVersion(at: validationURL),
                snapshotVersion: UpdateOperationRecoveryPlan.bundleShortVersion(at: snapshotURL)
            ) {
                WegaLog.error(
                    .homebrew,
                    "\(token): brew zakończył się sukcesem, ale na dysku została wersja sprzed aktualizacji — nic nie zainstalowano."
                )
                return .notUpgraded
            }

            let smokeTest = await launchSmokeTest(token: token, appURL: validationURL)
            guard !LaunchSmokeTest.requiresRollback(smokeTest) else {
                return await restoreSnapshot(snapshotURL, to: validationURL) ? .rolledBack : .rollbackFailed
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
        preservingSnapshot: Bool = false,
        dependencies: Dependencies? = nil
    ) async -> Bool {
        let restorationSource: URL
        if preservingSnapshot {
            restorationSource = snapshot.deletingLastPathComponent()
                .appendingPathComponent("restore-\(UUID().uuidString).app")
            do {
                if let dependencies {
                    try dependencies.clone(snapshot, restorationSource)
                } else {
                    try BundleSnapshot.clone(snapshot, to: restorationSource)
                }
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
                // Cleanup is best-effort; the retained original snapshot remains recoverable.
                if let dependencies {
                    try? dependencies.removeItem(restorationSource)
                } else {
                    try? FileManager.default.removeItem(at: restorationSource)
                }
            }
        }

        do {
            if let dependencies {
                try dependencies.restore(restorationSource, appURL)
            } else {
                try BundleSnapshot.restore(snapshot: restorationSource, to: appURL)
            }
            return true
        } catch {
            let helperIsEnabled = dependencies?.helperIsEnabled()
                ?? PrivilegedHelperClient.shared.isEnabled
            guard helperIsEnabled else { return false }
            do {
                if let dependencies {
                    try await dependencies.helperReplace(appURL.path, restorationSource.path)
                } else {
                    try await PrivilegedHelperClient.shared.replaceBundle(
                        at: appURL.path, withSnapshotAt: restorationSource.path
                    )
                }
                return true
            } catch {
                WegaLog.error(.helper, "Rollback przez helper nie powiódł się: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// LT-02 — starts the upgraded app hidden and reports whether it survived the window.
    ///
    /// The verdict is narrated here rather than inside `LaunchSmokeTest` so the decision
    /// logic stays a pure function in Core; what the caller does with it — restore or keep —
    /// is `requiresRollback`, not this log line.
    private static func launchSmokeTest(
        token: String,
        appURL: URL,
        dependencies: Dependencies? = nil
    ) async -> LaunchSmokeTest.Verdict {
        let verdict: LaunchSmokeTest.Verdict
        if let dependencies {
            guard dependencies.smokeTestIsEnabled() else { return .skipped(.disabled) }
            verdict = await dependencies.launchSmokeTest(appURL)
        } else {
            guard LaunchSmokeTestConfiguration.isEnabled() else { return .skipped(.disabled) }
            verdict = await LaunchSmokeTest.run(bundleAt: appURL, probe: WorkspaceAppLaunchProbe())
        }
        switch verdict {
        case .survived:
            WegaLog.info(.homebrew, "\(token): nowa wersja uruchomiła się i przeżyła test startu.")
        case .exitedEarly(let after):
            WegaLog.error(
                .homebrew,
                "\(token): nowa wersja zakończyła się \(String(format: "%.1f", after)) s po starcie — przywracam poprzednią wersję."
            )
        case .launchFailed(let message):
            WegaLog.error(
                .homebrew,
                "\(token): nowej wersji nie udało się uruchomić (\(message)) — przywracam poprzednią wersję."
            )
        case .skipped(let reason):
            WegaLog.info(.homebrew, "\(token): test startu pominięty (\(reason)).")
        }
        return verdict
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

    private(set) var isBusy: Bool

    private init() {
        isBusy = false
    }

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
