import Foundation
import MacUpdaterCore

/// What the user can do about an app that was not removed.
enum UninstallResultAction: Equatable {
    case showInFinder(URL)
    case openAppManagementSettings
    /// Reserved for the helper-based removal; no result offers it yet.
    case openHelperSettings

    var title: String {
        switch self {
        case .showInFinder: tr("Pokaż w Finderze")
        case .openAppManagementSettings: tr("Otwórz ustawienia prywatności")
        case .openHelperSettings: tr("Otwórz ustawienia pomocnika")
        }
    }
}

/// One button under the result: the app it concerns and what pressing it does.
struct UninstallResultActionItem: Identifiable, Equatable {
    let appName: String
    let action: UninstallResultAction

    var id: String { "\(appName)|\(action.title)" }
}

/// Turns the per-target results of an uninstall run into the one banner and one error the
/// view shows, so every app that was not removed is named with its own reason.
enum UninstallResultPresentation {
    static func summary(
        results: [String: UninstallTargetResult],
        apps: [ApplicationInfo],
        leftoversTrashed: Int,
        leftoversFailed: Int,
        requestedZap: Bool = false
    ) -> (banner: BannerData?, error: String?) {
        let reported = apps.filter { results[$0.id] != nil }
        let removed = reported.filter { results[$0.id]?.isRemoved == true }
        return (
            banner: successBanner(removed: removed, leftoversTrashed: leftoversTrashed),
            error: errorMessage(
                reported: reported, results: results, leftoversFailed: leftoversFailed, requestedZap: requestedZap
            )
        )
    }

    static func actions(for result: UninstallTargetResult, app: ApplicationInfo) -> [UninstallResultAction] {
        switch result {
        case .blocked(.needsAppManagement):
            return [.openAppManagementSettings]
        case .blocked(.needsAdministratorRights):
            return [.showInFinder(app.path)]
        case .leftInStaging(let url):
            return [.showInFinder(url)]
        case .removedByHomebrew, .movedToTrash, .movedToTrashByHelper, .skippedStillRunning,
             .skippedAmbiguousProcess, .blocked, .failed, .protected:
            return []
        }
    }

    /// The buttons for every app that was not removed, in the order of `apps`.
    static func actionItems(
        results: [String: UninstallTargetResult],
        apps: [ApplicationInfo]
    ) -> [UninstallResultActionItem] {
        apps.flatMap { app -> [UninstallResultActionItem] in
            guard let result = results[app.id] else { return [] }
            return actions(for: result, app: app).map { UninstallResultActionItem(appName: app.name, action: $0) }
        }
    }

    private static func successBanner(removed: [ApplicationInfo], leftoversTrashed: Int) -> BannerData? {
        guard !removed.isEmpty else { return nil }
        let brewCount = removed.filter(\.isManagedByBrew).count
        let trashCount = removed.count - brewCount
        var parts: [String] = []
        if brewCount > 0 { parts.append(trf("%@ przez brew", "\(brewCount)")) }
        if trashCount > 0 { parts.append(trf("%@ do Kosza", "\(trashCount)")) }
        // UX-13: report the leftovers that reached the Trash alongside the app removals.
        if leftoversTrashed > 0 { parts.append(trf("%@ resztek do Kosza", "\(leftoversTrashed)")) }
        return BannerData(
            variant: .success,
            title: trf("Odinstalowano %@ aplikacji", "\(removed.count)"),
            message: parts.joined(separator: ", ")
        )
    }

    private static func errorMessage(
        reported: [ApplicationInfo],
        results: [String: UninstallTargetResult],
        leftoversFailed: Int,
        requestedZap: Bool
    ) -> String? {
        var parts: [String] = []
        if let failure = failureNote(reported: reported, results: results, zap: requestedZap) { parts.append(failure) }
        for app in reported {
            if let result = results[app.id], let line = notRemovedLine(app: app, result: result) {
                parts.append(line)
            }
        }
        // UX-13: leftovers that could not be moved are surfaced, not swallowed.
        if leftoversFailed > 0 {
            parts.append(trf("Nie udało się przenieść %@ resztek do Kosza.", "\(leftoversFailed)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The generic "incomplete" text is reserved for removals that failed for a reason the
    /// app cannot name; every other outcome carries its own reason in `notRemovedLine`.
    private static func failureNote(
        reported: [ApplicationInfo],
        results: [String: UninstallTargetResult],
        zap: Bool
    ) -> String? {
        var failed: [(name: String, requestedZap: Bool)] = []
        var details: [String] = []
        for app in reported {
            guard case .failed(let reason) = results[app.id] else { continue }
            details.append(reason.isEmpty ? app.name : "\(app.name) (\(reason))")
            if app.isManagedByBrew {
                failed.append((app.name, zap))
            } else {
                failed.append((app.name, false))
            }
        }
        guard !failed.isEmpty else { return nil }
        var note = trf(
            "Odinstalowanie niepełne — nie usunięto: %@",
            "\(details.joined(separator: ", "))"
        )
        if failed.contains(where: \.requestedZap) {
            note += " " + tr("Nie uruchomiono --force; wybrane usunięcie wraz z resztkami nie zostało po cichu zmienione.")
        }
        return note
    }

    private static func notRemovedLine(app: ApplicationInfo, result: UninstallTargetResult) -> String? {
        switch result {
        case .removedByHomebrew, .movedToTrash, .movedToTrashByHelper, .failed:
            return nil
        case .skippedStillRunning:
            return trf("%@ — pominięta, bo nadal działa.", app.name)
        case .skippedAmbiguousProcess:
            return trf("%@ — pominięta, bo nie da się jednoznacznie wskazać jej procesu.", app.name)
        case .blocked(let block):
            return trf("%@ — %@", app.name, blockReason(block))
        case .leftInStaging(let url):
            return trf("%@ — została w katalogu tymczasowym: %@", app.name, url.path)
        case .protected(let protection):
            return trf("%@ — %@", app.name, UninstallProtectionPresentation.protectionReason(protection))
        }
    }

    /// The reason a removal was blocked, shared with the preflight label in the confirmation.
    static func blockReason(_ block: UninstallBlock) -> String {
        switch block {
        case .needsHelper:
            tr("wymaga pomocnika Wega — włącz go w ustawieniach.")
        case .needsAdministratorAccount:
            tr("wymaga konta administratora.")
        case .needsAdministratorRights:
            tr("wymaga uprawnień administratora — usuń ją w Finderze.")
        case .needsAppManagement:
            tr("macOS blokuje usuwanie — zezwól Wega w Zarządzaniu aplikacjami.")
        }
    }
}
