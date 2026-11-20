import Foundation
import MacUpdaterCore

/// What the user can do about an app that was not removed.
enum UninstallResultAction: Equatable {
    case showInFinder(URL)
    case openAppManagementSettings
    /// Opens Wega's Settings window, whose helper card turns the helper on.
    case openHelperSettings

    var title: String {
        switch self {
        case .showInFinder: tr("Pokaż w Finderze")
        case .openAppManagementSettings: tr("Otwórz ustawienia prywatności")
        case .openHelperSettings: tr("Otwórz ustawienia pomocnika")
        }
    }
}

/// One app that was not removed: which copy it is, why it stayed, and what helps.
struct UninstallResultRow: Identifiable, Equatable {
    /// `ApplicationInfo.id`, so two copies of one app never share a row or its buttons.
    let id: String
    let name: String
    /// Where this copy lives, set when another reported app shares its name or bundle identifier.
    let location: String?
    let reason: String
    /// The complete error text when `reason` shows only its key line.
    let detail: String?
    let actions: [UninstallResultAction]
}

/// The outcome of one uninstall run as the view shows it: a success banner naming what was
/// removed, one summary line, and one row per app that was not removed.
struct UninstallResultReport: Equatable {
    let banner: BannerData?
    let summary: String?
    let rows: [UninstallResultRow]
}

/// Turns the per-target results of an uninstall run into what the view shows, so every app
/// that was not removed is named with its own reason, however many there are.
enum UninstallResultPresentation {
    static func report(
        results: [String: UninstallTargetResult],
        apps: [ApplicationInfo],
        leftoversTrashed: Int,
        leftoversFailed: Int,
        requestedZap: Bool = false
    ) -> UninstallResultReport {
        let reported = apps.filter { results[$0.id] != nil }
        let removed = reported.filter { results[$0.id]?.isRemoved == true }
        let rows = rows(results: results, apps: reported)
        return UninstallResultReport(
            banner: successBanner(removed: removed, results: results, leftoversTrashed: leftoversTrashed),
            summary: summaryLine(
                reported: reported, results: results, rows: rows,
                leftoversFailed: leftoversFailed, requestedZap: requestedZap
            ),
            rows: rows
        )
    }

    /// One row per app that was not removed, in the order of `apps`.
    static func rows(results: [String: UninstallTargetResult], apps: [ApplicationInfo]) -> [UninstallResultRow] {
        let sharedNames = Set(Dictionary(grouping: apps, by: \.name).filter { $0.value.count > 1 }.keys)
        let sharedBundleIDs = InstallationInventory.ambiguousBundleIdentifiers(apps)
        return apps.compactMap { app -> UninstallResultRow? in
            guard let result = results[app.id], let explanation = explanation(of: result, app: app) else { return nil }
            let isShared = sharedNames.contains(app.name)
                || app.bundleIdentifier.map(sharedBundleIDs.contains) == true
            return UninstallResultRow(
                id: app.id,
                name: app.name,
                location: isShared ? app.locationLabel : nil,
                reason: explanation.reason,
                detail: explanation.detail,
                actions: actions(for: result, app: app)
            )
        }
    }

    static func actions(for result: UninstallTargetResult, app: ApplicationInfo) -> [UninstallResultAction] {
        switch result {
        case .blocked(.needsAppManagement):
            return [.openAppManagementSettings]
        case .blocked(.needsHelper), .blocked(.helperNeedsReinstall):
            return [.openHelperSettings, .showInFinder(app.path)]
        case .blocked(.needsAdministratorRights), .blocked(.needsAdministratorAccount):
            return [.showInFinder(app.path)]
        case .leftInStaging(let url):
            return [.showInFinder(url)]
        case .removedByHomebrew, .movedToTrash, .movedToTrashByHelper, .skippedStillRunning,
             .skippedAmbiguousProcess, .blocked, .failed, .protected:
            return []
        }
    }

    /// A failure's key line: brew's `Error:` line when the text has one, otherwise its first
    /// line. The complete text stays as `detail` whenever the key line leaves part of it out,
    /// so brew's untranslated, unbounded stderr never stands in for the reason.
    static func failureReason(_ text: String) -> (reason: String, detail: String?) {
        let full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = full.components(separatedBy: .newlines)
        // `BrewServiceError` puts its own "brew … failed with exit code N: " before stderr, so the
        // line ScanLog finds may start with that prefix; the reason starts at brew's "Error:".
        let errorLine = ScanLog.brewErrorReason(from: lines).map { line in
            line.range(of: "Error:").map { String(line[$0.lowerBound...]) } ?? line
        }
        let reason = errorLine ?? lines.first ?? full
        return (reason, reason == full ? nil : full)
    }

    private static func explanation(
        of result: UninstallTargetResult,
        app: ApplicationInfo
    ) -> (reason: String, detail: String?)? {
        switch result {
        case .removedByHomebrew, .movedToTrash, .movedToTrashByHelper:
            return nil
        case .failed(let error):
            let shortened = failureReason(error)
            return shortened.reason.isEmpty ? (tr("nie udało się jej usunąć."), nil) : shortened
        case .skippedStillRunning:
            return (tr("pominięta, bo nadal działa."), nil)
        case .skippedAmbiguousProcess:
            return (tr("pominięta, bo nie da się jednoznacznie wskazać jej procesu."), nil)
        case .blocked(let block):
            return (blockReason(block), nil)
        case .leftInStaging(let url):
            return (trf("została w katalogu tymczasowym: %@", url.path), nil)
        case .protected(let protection):
            return (UninstallProtectionPresentation.protectionReason(protection), nil)
        }
    }

    private static func successBanner(
        removed: [ApplicationInfo],
        results: [String: UninstallTargetResult],
        leftoversTrashed: Int
    ) -> BannerData? {
        guard !removed.isEmpty else { return nil }
        var parts = removed.map { app in
            switch results[app.id] {
            case .removedByHomebrew: trf("%@ przez brew", app.name)
            case .movedToTrashByHelper: trf("%@ do Kosza przez pomocnika Wega", app.name)
            default: trf("%@ do Kosza", app.name)
            }
        }
        // UX-13: report the leftovers that reached the Trash alongside the app removals.
        if leftoversTrashed > 0 { parts.append(trp("%@ resztek do Kosza", leftoversTrashed)) }
        return BannerData(
            variant: .success,
            title: trp("Odinstalowano %@ aplikacji", removed.count),
            message: parts.joined(separator: ", ")
        )
    }

    /// One line above the rows. The reasons themselves are in the rows, so this stays short
    /// however many apps were left behind.
    private static func summaryLine(
        reported: [ApplicationInfo],
        results: [String: UninstallTargetResult],
        rows: [UninstallResultRow],
        leftoversFailed: Int,
        requestedZap: Bool
    ) -> String? {
        var parts: [String] = []
        let failure = failureNote(reported: reported, results: results, zap: requestedZap)
        if let failure { parts.append(failure.note) }
        let skippedCount = rows.count - (failure?.count ?? 0)
        if skippedCount > 0 {
            parts.append(trp("Pominięto %@ aplikacji — powody poniżej.", skippedCount))
        }
        // UX-13: leftovers that could not be moved are surfaced, not swallowed.
        if leftoversFailed > 0 {
            parts.append(trp("Nie udało się przenieść %@ resztek do Kosza.", leftoversFailed))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The generic "incomplete" text is reserved for removals that failed for a reason the
    /// app cannot name; every other outcome carries its own reason in its row.
    private static func failureNote(
        reported: [ApplicationInfo],
        results: [String: UninstallTargetResult],
        zap: Bool
    ) -> (note: String, count: Int)? {
        var failed: [(name: String, requestedZap: Bool)] = []
        for app in reported {
            guard case .failed = results[app.id] else { continue }
            if app.isManagedByBrew {
                failed.append((app.name, zap))
            } else {
                failed.append((app.name, false))
            }
        }
        guard !failed.isEmpty else { return nil }
        var note = trf(
            "Odinstalowanie niepełne — nie usunięto: %@. Powody poniżej.",
            "\(failed.map(\.name).joined(separator: ", "))"
        )
        if failed.contains(where: \.requestedZap) {
            note += " " + tr("Nie uruchomiono --force; wybrane usunięcie wraz z resztkami nie zostało po cichu zmienione.")
        }
        return (note, failed.count)
    }

    /// The reason a removal was blocked, shared with the preflight label in the confirmation.
    static func blockReason(_ block: UninstallBlock) -> String {
        switch block {
        case .needsHelper:
            tr("wymaga pomocnika Wega — włącz go w ustawieniach.")
        case .helperNeedsReinstall:
            tr("pomocnik Wega jest nieaktualny lub nie odpowiada — w ustawieniach usuń go i zainstaluj ponownie.")
        case .needsAdministratorAccount:
            tr("wymaga konta administratora.")
        case .needsAdministratorRights:
            tr("wymaga uprawnień administratora — usuń ją w Finderze.")
        case .needsAppManagement:
            tr("macOS blokuje usuwanie — zezwól Wega w Zarządzaniu aplikacjami.")
        }
    }
}
