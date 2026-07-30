import Foundation
import MacUpdaterCore
import UserNotifications

/// LT-01 — settles update operations a crash, kill or power loss cut short, at launch.
///
/// The journal (`UpdateOperationStore`) records every phase before acting on it, so the
/// file on disk is never behind the mutation. This runner walks operations whose items
/// stopped in a non-terminal phase and finishes them honestly:
///
///   * `planned` / `snapshotted` — brew never ran; the disk is untouched, the clone is
///     redundant. Settled `aborted`, clone deleted.
///   * `verified` — the canary had already passed; only the commit record is missing.
///     Settled `committed`.
///   * `installing` — the disk state is unknown. Probed: still the pre-upgrade version
///     means brew never finished (`aborted`); a different version means the upgrade went
///     through unvalidated, so it gets the same canary chain every upgrade gets — which
///     can roll it back; a *missing* app means the swap died mid-way and the snapshot is
///     put back by hand.
///
/// Anything it restores is said out loud — a silent repair of an app the user may have
/// been using for days is how trust in the feature dies.
@MainActor
final class UpdateOperationRecovery {
    static let shared = UpdateOperationRecovery()

    private let store: UpdateOperationStore
    private let dependencies: Dependencies

    init(store: UpdateOperationStore = .shared, dependencies: Dependencies = .live) {
        self.store = store
        self.dependencies = dependencies
    }

    struct Report: Equatable {
        var abortedTokens: [String] = []
        var committedTokens: [String] = []
        var rolledBackTokens: [String] = []
        var unrecoverableTokens: [String] = []

        var isEmpty: Bool {
            abortedTokens.isEmpty && committedTokens.isEmpty
                && rolledBackTokens.isEmpty && unrecoverableTokens.isEmpty
        }
    }

    struct Dependencies: Sendable {
        var fileExists: @Sendable (String) -> Bool
        var appVersion: @Sendable (URL) -> String?
        var verify: @MainActor @Sendable (
            [String], [String: URL], [String: URL], UpdateOperationSession
        ) async -> [String: CaskValidationVerdict]
        var clone: @Sendable (URL, URL) throws -> Void
        var recordRollback: @MainActor @Sendable (String) -> Void
        var removeItem: @Sendable (URL) throws -> Void
        var legacyDirectory: @Sendable () -> URL
        var announce: @MainActor @Sendable (Report) -> Void

        static let live = Dependencies(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            appVersion: {
                Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String
            },
            verify: { tokens, appPaths, snapshots, operation in
                await CaskRollbackGuard.verify(
                    tokens: tokens,
                    appPaths: appPaths,
                    snapshots: snapshots,
                    operation: operation
                )
            },
            clone: { try BundleSnapshot.clone($0, to: $1) },
            recordRollback: {
                CaskRollbackLedger.shared.recordRollback(token: $0, reason: .checkFailed)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            legacyDirectory: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("wega-rollback", isDirectory: true)
            },
            announce: { announceLive($0) }
        )
    }

    /// Runs once per launch, before the background agent starts scheduling rounds.
    /// Also sweeps the pre-LT-01 shared temp directory (a crash orphan from an older
    /// build has no journal — deleting it is the only honest thing to do) and applies
    /// the retention window to finished operations.
    @discardableResult
    func recoverInterruptedOperations() async -> Report {
        sweepLegacyTempSnapshots()

        var report = Report()
        for operation in store.operations() where !operation.isFinished {
            guard let session = store.resumeSession(operationID: operation.id) else { continue }
            for item in session.operation.items where !item.phase.isTerminal {
                guard item.recoveryAttempts == 0 else { continue }
                session.noteRecoveryAttempt(token: item.token)
                switch UpdateOperationRecoveryPlan.action(for: item.phase) {
                case .abortWithoutMutation:
                    deleteSnapshot(of: item, operationID: operation.id)
                    session.markAborted(token: item.token)
                    report.abortedTokens.append(item.token)
                case .commitVerified:
                    session.markCommitted(token: item.token)
                    report.committedTokens.append(item.token)
                case .probeInstalledApp:
                    await settleInterruptedInstall(item: item, session: session, report: &report)
                case .settle:
                    break
                }
            }
        }

        let pruned = store.pruneExpired()
        if pruned > 0 {
            WegaLog.info(.app, "LT-01: retencja snapshotów — usunięto \(pruned) przeterminowanych kopii.")
        }
        guard !report.isEmpty else { return report }
        WegaLog.info(.app, "LT-01: recovery po przerwaniu — cofnięto: \(report.rolledBackTokens), "
            + "zatwierdzono: \(report.committedTokens), porzucono bez mutacji: \(report.abortedTokens), "
            + "bez możliwości naprawy: \(report.unrecoverableTokens).")
        dependencies.announce(report)
        return report
    }

    // MARK: - installing

    private func settleInterruptedInstall(
        item: UpdateOperationItem,
        session: UpdateOperationSession,
        report: inout Report
    ) async {
        let appURL = URL(fileURLWithPath: item.appPath)
        let appExists = dependencies.fileExists(appURL.path)
        let installedVersion = appExists ? dependencies.appVersion(appURL) : nil

        switch UpdateOperationRecoveryPlan.installingProbe(
            appExists: appExists,
            installedVersion: installedVersion,
            preUpgradeVersion: item.preUpgradeVersion
        ) {
        case .untouched:
            deleteSnapshot(of: item, operationID: session.operation.id)
            session.markAborted(token: item.token)
            report.abortedTokens.append(item.token)
        case .mutated:
            // The upgrade landed but was never validated: run it through the same canary
            // chain as a live upgrade — Gatekeeper, publisher baseline, rollback on
            // rejection. The guard journals the verdict into the resumed session.
            let snapshots = snapshotMap(for: item, operationID: session.operation.id)
            let verdicts = await dependencies.verify(
                [item.token], [item.token: appURL], snapshots, session
            )
            switch verdicts[item.token] {
            case .healthy:
                report.committedTokens.append(item.token)
            case .rolledBack, .publisherChangedAndRolledBack:
                report.rolledBackTokens.append(item.token)
            case .rollbackFailed, .publisherChanged, nil:
                report.unrecoverableTokens.append(item.token)
            }
        case .appMissing:
            await restoreMissingApp(item: item, session: session, report: &report)
        }
    }

    /// The swap died mid-way and left no app at the recorded path. `replaceItemAt` needs
    /// an existing target, so the snapshot is *cloned* into place rather than moved —
    /// keeping the original for the retention window, exactly like a publisher-mismatch
    /// rollback does.
    private func restoreMissingApp(
        item: UpdateOperationItem,
        session: UpdateOperationSession,
        report: inout Report
    ) async {
        let appURL = URL(fileURLWithPath: item.appPath)
        guard let snapshotURL = snapshotMap(for: item, operationID: session.operation.id)[item.token] else {
            WegaLog.error(.homebrew, "LT-01: \(item.token): aplikacja zniknęła, a snapshot nie istnieje — nic do przywrócenia.")
            report.unrecoverableTokens.append(item.token)
            return
        }
        do {
            try dependencies.clone(snapshotURL, appURL)
            session.markRolledBack(token: item.token)
            dependencies.recordRollback(item.token)
            report.rolledBackTokens.append(item.token)
            WegaLog.error(.homebrew, "LT-01: \(item.token): przerwana instalacja usunęła aplikację — przywrócono z klona.")
        } catch {
            WegaLog.error(.homebrew, "LT-01: \(item.token): przywrócenie znikniętej aplikacji nie powiodło się — \(error.localizedDescription)")
            report.unrecoverableTokens.append(item.token)
        }
    }

    // MARK: - helpers

    private func snapshotMap(for item: UpdateOperationItem, operationID: UUID) -> [String: URL] {
        guard let name = item.snapshotName else { return [:] }
        let url = store.snapshotURL(operationID: operationID, name: name)
        return dependencies.fileExists(url.path) ? [item.token: url] : [:]
    }

    private func deleteSnapshot(of item: UpdateOperationItem, operationID: UUID) {
        guard let name = item.snapshotName else { return }
        try? dependencies.removeItem(store.snapshotURL(operationID: operationID, name: name))
    }

    /// Pre-LT-01 builds cloned into one shared, predictable temp directory and a crash
    /// left the clones there. No journal exists for them, so there is nothing to settle —
    /// only to sweep.
    private func sweepLegacyTempSnapshots() {
        let legacy = dependencies.legacyDirectory()
        guard dependencies.fileExists(legacy.path) else { return }
        try? dependencies.removeItem(legacy)
        WegaLog.info(.app, "LT-01: usunięto osierocone snapshoty sprzed journalu (wega-rollback).")
    }

    /// A restore that happened while nobody was watching must not stay private to the
    /// log file — same reasoning as the background round's notification.
    private static func announceLive(_ report: Report) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard !report.rolledBackTokens.isEmpty || !report.unrecoverableTokens.isEmpty else { return }
        let body: String
        if !report.unrecoverableTokens.isEmpty {
            body = trf("Przerwana aktualizacja: %@ nie udało się naprawić — sprawdź te aplikacje. %@ przywrócono z kopii.",
                       "\(report.unrecoverableTokens.joined(separator: ", "))",
                       "\(report.rolledBackTokens.joined(separator: ", "))")
        } else {
            body = trf("Przerwana aktualizacja dokończona: %@ przywrócono z kopii.",
                       "\(report.rolledBackTokens.joined(separator: ", "))")
        }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = tr("Wega naprawiła przerwaną aktualizację")
            content.body = body
            // OBS-02 — what recovery actually did exists only in the log, so that is where
            // this notification goes.
            content.userInfo = NotificationRouting.payload(for: NotificationRouting.recoveryDestination)
            let request = UNNotificationRequest(identifier: "wega.update-recovery", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
