import AppKit
import Foundation
import MacUpdaterCore
import UserNotifications

private struct BackgroundUpdatePreflight: Sendable {
    let profiles: [CaskArtifactProfile]
    let downloads: [CaskDownloadInfo]
    let appPaths: [String: URL]
}

/// Upgrades the safe subset of casks while nobody is watching (F3).
///
/// This is the only code path in Wega that changes the user's machine without them present,
/// so its preconditions are unusually strict and live in one pure, exhaustively tested place
/// (`BackgroundUpdatePlanner`). It reuses the same snapshot → canary → auto-rollback chain as
/// the window (`CaskRollbackGuard`), because "we can undo it" is the *reason* background
/// updating is defensible at all.
///
/// Not a daemon: it runs inside the menu-bar agent, so nothing happens while Wega is closed.
/// The UI says so rather than implying a system service.
@MainActor
final class BackgroundUpdater {
    static let shared = BackgroundUpdater()

    private let brewService = BrewService()

    private init() {}

    /// Runs after a scheduled background check. Does nothing — silently and by design —
    /// when nothing qualifies, when the window is mid-upgrade, or when no app is opted in.
    /// Returns the tokens it upgraded, for the notification.
    @discardableResult
    func runIfEligible(candidates: [String], policies: [String: UpdatePolicy]) async -> [String] {
        let optedIn = BackgroundUpdateOptInStore.shared.tokens
        guard !candidates.isEmpty, !optedIn.isEmpty else { return [] }

        let preflight: BackgroundUpdatePreflight
        do {
            preflight = try await OperationCoordinator.shared.withReadLease(
                label: "background update preflight"
            ) { @MainActor _ in
                await self.loadPreflight(candidates: candidates)
            }
        } catch {
            return []
        }
        let profiles = preflight.profiles
        let downloads = preflight.downloads
        let appPaths = preflight.appPaths

        let pathBackedCandidates = BackgroundUpdateSafety.pathBackedTokens(candidates, appPaths: appPaths)
        let downloadsByToken = Dictionary(
            downloads.map { ($0.token, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let initiallyEligibleTokens = BackgroundUpdatePlanner.eligibleTokens(.init(
            candidates: pathBackedCandidates,
            profiles: Dictionary(profiles.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first }),
            downloads: downloadsByToken,
            optedIn: optedIn,
            runningProcessTokens: runningTokens(appPaths: appPaths),
            policies: policies
        ))
        guard !initiallyEligibleTokens.isEmpty else { return [] }
        let downloadSizes = await DownloadResourcePreflight.probe(
            tokens: initiallyEligibleTokens,
            downloads: downloadsByToken
        )

        return (try? await UpgradeCoordinator.shared.performWrite(.backgroundUpgrade) {
            // F3 — the shared write queue admits only one Homebrew mutation at a time. Keep
            // the legacy mutex check as a fail-closed guard for callers outside that boundary.
            guard UpgradeMutex.shared.acquire() else {
                WegaLog.info(.homebrew, "Aktualizacja w tle pominięta — trwa aktualizacja z okna.")
                return []
            }
            defer { UpgradeMutex.shared.release() }

            // Policy and process state can change while this round waits for the window. Once
            // the mutex is ours, every mutable veto is sampled again before any mutation.
            let lockedPolicies = UpdatePolicyStore.shared.policiesMap
            let lockedRunningProcessTokens = runningTokens(appPaths: appPaths)
            let eligibleLockedTokens = BackgroundUpdatePlanner.eligibleTokens(.init(
                candidates: initiallyEligibleTokens,
                profiles: Dictionary(profiles.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first }),
                downloads: Dictionary(downloads.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first }),
                optedIn: BackgroundUpdateOptInStore.shared.tokens,
                runningProcessTokens: lockedRunningProcessTokens,
                policies: lockedPolicies
            ))
            guard !eligibleLockedTokens.isEmpty else { return [] }

            let resourceDecision = await backgroundResourceDecision(
                tokens: eligibleLockedTokens,
                downloadSizes: downloadSizes,
                appPaths: appPaths
            )
            guard case .allow = resourceDecision else {
                if case .postpone(let reason) = resourceDecision {
                    WegaLog.info(.homebrew, "Aktualizacja w tle odroczona — \(reason).")
                }
                return []
            }

            let publisherVetoes = CaskRollbackGuard.publisherVetoes(
                tokens: eligibleLockedTokens, appPaths: appPaths
            )
            let lockedTokens = eligibleLockedTokens.filter { publisherVetoes[$0] == nil }
            let snapshots = CaskRollbackGuard.snapshot(tokens: lockedTokens, appPaths: appPaths)
            let tokens = BackgroundUpdateSafety.snapshotBackedTokens(lockedTokens, snapshots: snapshots)
            var run = UpdateRunOutcome()
            run.recordPublisherVetoes(eligibleLockedTokens.map(Self.caskItem), audits: publisherVetoes)
            for token in lockedTokens where snapshots[token] == nil {
                WegaLog.error(
                    .homebrew,
                    "\(token): aktualizacja w tle odroczona — nie udało się utworzyć wymaganego snapshotu."
                )
            }
            guard !tokens.isEmpty else {
                if run.summary.isEmpty {
                    WegaLog.error(.homebrew, "Aktualizacja w tle pominięta — nie udało się utworzyć snapshotu.")
                } else {
                    notify(summary: run.summary)
                }
                return []
            }

            WegaLog.info(.homebrew, "Aktualizacja w tle: \(tokens.joined(separator: ", "))")

            let command = UpdatePlanner.commands(for: UpdatePlanner.plan(
                selectedKeys: Set(tokens.map { "c:\($0)" }),
                allKeys: tokens.map { "c:\($0)" }
            ))
            guard let arguments = command.first(where: { $0.executable == "brew" })?.arguments else { return [] }

            // REL-02 — the same per-item result type the window builds, filled in by the same
            // phases: execution, validation/rollback, then a rescan that has to agree.
            run.recordBackgroundRound(tokens.map(Self.caskItem), outcome: await runBrew(arguments: arguments))
            run.applyValidation(await CaskRollbackGuard.verify(tokens: tokens, appPaths: appPaths, snapshots: snapshots))
            await confirmByRescan(&run)

            let summary = run.summary
            for outcome in summary.items where outcome.verdict != .succeeded {
                WegaLog.error(.homebrew, "\(outcome.name): aktualizacja w tle — \(outcome.verdict.logDescription).")
            }

            notify(summary: summary)
            return summary.upgraded.map(\.name)
        }) ?? []
    }

    private func loadPreflight(candidates: [String]) async -> BackgroundUpdatePreflight {
        let profiles: [CaskArtifactProfile]
        do {
            profiles = try await brewService.caskArtifactProfiles(tokens: candidates)
        } catch {
            WegaLog.error(.homebrew, "Aktualizacja w tle — profile artefaktów: \(error.localizedDescription)")
            profiles = []
        }
        let downloads: [CaskDownloadInfo]
        do {
            downloads = try await brewService.caskDownloadInfo(tokens: candidates)
        } catch {
            WegaLog.error(.homebrew, "Aktualizacja w tle — dane pobierania: \(error.localizedDescription)")
            downloads = []
        }
        return BackgroundUpdatePreflight(
            profiles: profiles,
            downloads: downloads,
            appPaths: await resolveAppPaths(tokens: candidates)
        )
    }

    /// The last phase: ask brew again what is outdated. A cask brew claims to have upgraded
    /// and still lists as outdated was not upgraded, and a query that fails leaves the round
    /// unconfirmed — which the notification says rather than glossing over.
    private func confirmByRescan(_ run: inout UpdateRunOutcome) async {
        let outdated: BrewOutdated
        do {
            outdated = try await brewService.outdatedGreedy()
        } catch {
            WegaLog.error(.homebrew, "Aktualizacja w tle — skan potwierdzający: \(error.localizedDescription)")
            run.applyRescan(stillOutdatedKeys: [], confirmed: false)
            return
        }
        run.applyRescan(stillOutdatedKeys: Set(outdated.casks.map { Self.caskItem($0.name).key }),
                        confirmed: true)
    }

    private static func caskItem(_ token: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: token, kind: .cask), name: token,
                     from: nil, to: nil, kind: .cask)
    }

    /// Which of these casks own an app that is running right now. Matched by bundle URL, not
    /// by a guessed process name: replacing a live app's bundle is how you corrupt a session.
    private func runningTokens(appPaths: [String: URL]) -> Set<String> {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleURL?.standardizedFileURL))
        return Set(appPaths.filter { running.contains($0.value.standardizedFileURL) }.keys)
    }

    /// REL-03 — the resolution itself now lives in `CaskAppPathResolver`, shared with the
    /// window path, which used to read a map only a full scan ever filled.
    private func resolveAppPaths(tokens: [String]) async -> [String: URL] {
        do {
            let infos = try await brewService.caskInstallationInfo(tokens: tokens)
            return CaskAppPathResolver().appPaths(from: infos)
        } catch {
            WegaLog.error(.homebrew, "Aktualizacja w tle — ścieżki aplikacji: \(error.localizedDescription)")
            return [:]
        }
    }

    private func backgroundResourceDecision(
        tokens: [String],
        downloadSizes: [String: DownloadSizeProbeResult],
        appPaths: [String: URL]
    ) async -> DownloadGate.Decision {
        await DownloadResourcePreflight.decision(
            tokens: tokens,
            downloadSizes: downloadSizes,
            appPaths: appPaths
        )
    }

    private func runBrew(arguments: [String]) async -> BrewUpgradeOutcome {
        var captured = ""
        var exitCode: Int32 = 0
        let brewOutcome: BrewUpgradeOutcome
        do {
            for try await event in try brewService.events(arguments: arguments) {
                switch event {
                case .stdout(let chunk), .stderr(let chunk): captured += chunk
                case .finished(let result): exitCode = result.exitCode
                }
            }
            brewOutcome = BrewUpgradeOutcome.analyze(exitCode: exitCode, output: captured)
        } catch {
            brewOutcome = BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: [error.localizedDescription])
        }
        for line in brewOutcome.errorLines {
            WegaLog.error(.homebrew, "Aktualizacja w tle — brew: \(line)")
        }
        return brewOutcome
    }

    /// Reports what happened — every outcome, not just the happy one. A background updater
    /// that only ever announces success is one you cannot trust with the failures, and a
    /// round whose *only* result was a changed publisher or a failed rollback used to post
    /// no notification at all.
    private func notify(summary: UpdateRunSummary) {
        guard Bundle.main.bundleIdentifier != nil, !summary.isEmpty else { return }
        let title = summary.critical.isEmpty
            ? tr("Aktualizacje w tle")
            : tr("Aktualizacje w tle — wymagają uwagi")
        let body = Self.notificationBody(for: summary)
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: "wega.background-updates", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// One clause per outcome the round produced, so the notification cannot claim a clean
    /// sweep over a rollback that failed or a publisher that changed.
    private static func notificationBody(for summary: UpdateRunSummary) -> String {
        let rolledBack = summary.names { $0 == .rolledBack }
        let rollbackFailed = summary.rollbackFailures.map(\.name)
        let publisherChanged = summary.publisherChanges.map(\.name)
        let failed = summary.names { $0 == .executionFailed || $0 == .stillOutdated || $0 == .notVerified }

        var clauses: [String] = [trf("Zaktualizowano %@ w tle.", "\(summary.upgraded.count)")]
        if !rolledBack.isEmpty {
            clauses.append(trf("%@ cofnięto po nieudanym teście.", "\(rolledBack.count)"))
        }
        if !rollbackFailed.isEmpty {
            clauses.append(trf("%@ nie przeszło testu i nie udało się przywrócić — sprawdź je.",
                               "\(rollbackFailed.joined(separator: ", "))"))
        }
        if !publisherChanged.isEmpty {
            clauses.append(trf("%@ zmieniło wydawcę (Team ID) — zweryfikuj.",
                               "\(publisherChanged.joined(separator: ", "))"))
        }
        if !failed.isEmpty {
            clauses.append(trf("%@ nie udało się zaktualizować.", "\(failed.count)"))
        }
        return clauses.joined(separator: " · ")
    }
}
