import AppKit
import Foundation
import MacUpdaterCore
import UserNotifications

/// Per-app opt-in for unattended upgrades (F3).
///
/// Deliberately *not* a new case on `UpdatePolicy`, despite the strategy note suggesting it:
/// a policy holds exactly one value per key, so `.autoUpdate` could not coexist with
/// `.pinned(version:)`, and "update this automatically, but never past 18" is a combination
/// a user is entitled to. Same store pattern, separate concern.
@MainActor
final class BackgroundUpdateOptInStore: ObservableObject {
    static let shared = BackgroundUpdateOptInStore()

    private static let defaultsKey = "wega.backgroundUpdate.optIn"

    @Published private(set) var tokens: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        tokens = Set(stored)
    }

    func isOptedIn(_ token: String) -> Bool { tokens.contains(token) }

    func setOptedIn(_ optedIn: Bool, token: String) {
        if optedIn { tokens.insert(token) } else { tokens.remove(token) }
        UserDefaults.standard.set(Array(tokens), forKey: Self.defaultsKey)
    }
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

        let profiles = (try? await brewService.caskArtifactProfiles(tokens: candidates)) ?? []
        let downloads = (try? await brewService.caskDownloadInfo(tokens: candidates)) ?? []
        let appPaths = await resolveAppPaths(tokens: candidates)

        let tokens = BackgroundUpdatePlanner.eligibleTokens(.init(
            candidates: candidates,
            profiles: Dictionary(profiles.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first }),
            downloads: Dictionary(downloads.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first }),
            optedIn: optedIn,
            runningProcessTokens: runningTokens(appPaths: appPaths),
            policies: policies
        ))
        guard !tokens.isEmpty else { return [] }

        // F3 — the window always wins. If the user is upgrading by hand right now, this
        // round is skipped entirely; the next scheduled check will pick it up.
        guard UpgradeMutex.shared.acquire() else {
            WegaLog.info(.homebrew, "Aktualizacja w tle pominięta — trwa aktualizacja z okna.")
            return []
        }
        defer { UpgradeMutex.shared.release() }

        WegaLog.info(.homebrew, "Aktualizacja w tle: \(tokens.joined(separator: ", "))")
        let snapshots = CaskRollbackGuard.snapshot(tokens: tokens, appPaths: appPaths)

        let command = UpdatePlanner.commands(for: UpdatePlanner.plan(
            selectedKeys: Set(tokens.map { "c:\($0)" }),
            allKeys: tokens.map { "c:\($0)" }
        ))
        guard let arguments = command.first(where: { $0.executable == "brew" })?.arguments else { return [] }

        let outcome = await runBrew(arguments: arguments)
        let verdicts = await CaskRollbackGuard.verify(tokens: tokens, appPaths: appPaths, snapshots: snapshots)

        let succeeded = tokens.filter { token in
            !outcome.failedTokens.contains(token) && verdicts[token] == .healthy
        }
        let rolledBack = verdicts.filter { $0.value == .rolledBack }.map(\.key)
        for (token, verdict) in verdicts {
            switch verdict {
            case .rolledBack:
                WegaLog.error(.homebrew, "\(token): aktualizacja w tle cofnięta — nowa wersja nie przeszła kontroli.")
            case .rollbackFailed:
                WegaLog.error(.homebrew, "\(token): aktualizacja w tle nie przeszła kontroli, a rollback się nie powiódł.")
            case .publisherChanged(let old, let new):
                WegaLog.error(.homebrew, "\(token): Team ID zmienił się (\(old) → \(new ?? "—")). Zweryfikuj.")
            case .healthy:
                continue
            }
        }

        notify(upgraded: succeeded, rolledBack: rolledBack)
        return succeeded
    }

    /// Which of these casks own an app that is running right now. Matched by bundle URL, not
    /// by a guessed process name: replacing a live app's bundle is how you corrupt a session.
    private func runningTokens(appPaths: [String: URL]) -> Set<String> {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleURL?.standardizedFileURL))
        return Set(appPaths.filter { running.contains($0.value.standardizedFileURL) }.keys)
    }

    private func resolveAppPaths(tokens: [String]) async -> [String: URL] {
        let infos = (try? await brewService.caskInstallationInfo(tokens: tokens)) ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [String: URL] = [:]
        for info in infos {
            for artifact in info.appArtifacts {
                let system = SystemPaths.applicationsDirectory.appendingPathComponent(artifact)
                let user = home.appendingPathComponent("Applications/\(artifact)")
                if FileManager.default.fileExists(atPath: system.path) {
                    paths[info.token] = system; break
                } else if FileManager.default.fileExists(atPath: user.path) {
                    paths[info.token] = user; break
                }
            }
        }
        return paths
    }

    private func runBrew(arguments: [String]) async -> BrewUpgradeOutcome {
        var captured = ""
        var exitCode: Int32 = 0
        do {
            for try await event in try brewService.events(arguments: arguments) {
                switch event {
                case .stdout(let chunk), .stderr(let chunk): captured += chunk
                case .finished(let result): exitCode = result.exitCode
                }
            }
        } catch {
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: [error.localizedDescription])
        }
        return BrewUpgradeOutcome.analyze(exitCode: exitCode, output: captured)
    }

    /// Reports what happened, including the rollbacks. A background updater that only ever
    /// announces success is one you cannot trust with the failures.
    private func notify(upgraded: [String], rolledBack: [String]) {
        guard Bundle.main.bundleIdentifier != nil, !(upgraded.isEmpty && rolledBack.isEmpty) else { return }
        let body: String
        if rolledBack.isEmpty {
            body = trf("Zaktualizowano %@ w tle · wszystkie przeszły test.", "\(upgraded.count)")
        } else {
            body = trf("Zaktualizowano %@ w tle · %@ cofnięto po nieudanym teście.",
                       "\(upgraded.count)", "\(rolledBack.count)")
        }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = tr("Aktualizacje w tle")
            content.body = body
            let request = UNNotificationRequest(identifier: "wega.background-updates", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
