import Foundation
import MacUpdaterCore

extension CleanupPresentation {
    /// Paths inside a reason are shown as given; callers pass them with `~` already substituted.
    static func reasonText(_ reason: CleanupReason) -> String {
        reasonText(reason, requiredBy: [])
    }

    /// `requiredBy` holds the paths of a `.pinned` status, which the reason `.requiredByProjects`
    /// names; the plain-text export lists them in a field of their own.
    static func reasonText(_ reason: CleanupReason, requiredBy paths: [String]) -> String {
        switch reason {
        case .olderVersion(let current): trf("starsza wersja; bieżąca to %@", current)
        case .newerVersion(let current): trf("nowsza wersja; bieżąca to %@", current)
        case .shadowedBy(let path): trf("przesłania ją %@, wcześniej w PATH", path)
        case .systemCopy: tr("kopia dostarczana z macOS")
        case .managedByApp(let owner): trf("aktualizuje ją aplikacja %@", owner)
        case .staleSinceBoot(let count): trf("wpisy sprzed ostatniego uruchomienia systemu: %@", "\(count)")
        case .keptSinceBoot(let count): trf("wpisy z bieżącego uruchomienia, zostają: %@", "\(count)")
        case .unknownVersionDirectory: tr("katalog wersji, którego układu Wega nie zna")
        case .currentVersion: tr("bieżąca wersja")
        case .protectedLocation: tr("lokalizacja chroniona — Wega jej nie odczytuje")
        case .brokenLink: tr("dowiązanie wskazuje nieistniejący plik")
        case .requiredBy(let dependents): trf("potrzebna formułom: %@", dependents.joined(separator: ", "))
        case .homebrewLeftovers(let items):
            trf("stare wersje i pobrane pliki do usunięcia przez brew cleanup: %@", "\(items)")
        case .homebrewKeptVersions(let count):
            trf("Homebrew zostawia kilka wersji (%@) — przypięta formuła albo cask, który aktualizuje się sam", "\(count)")
        case .installedOnlyAsDependency: tr("zainstalowana tylko jako zależność; możesz jej jednak używać bezpośrednio")
        case .recentlyUpgraded: tr("zaktualizowana w ostatnich 7 dniach — poprzednie wersje zostają na wypadek przywracania")
        case .notRequiredByProjects: tr("nie wskazuje jej żaden projekt w katalogach projektów ani ustawienie menedżera")
        case .requiredByProjects: trf("wskazuje ją: %@", paths.isEmpty ? "—" : paths.joined(separator: ", "))
        case .unusedGradleDistribution: tr("nie wskazuje jej żaden wrapper Gradle; wrapper pobierze ją ponownie, gdy będzie potrzebna")
        case .unreferencedJDK(let major): trf("żaden projekt nie wymaga Javy %@", "\(major)")
        case .systemJDK(let major): trf("systemowa Java %@", "\(major)")
        case .ideVersionNotInstalled(let installed):
            trf("ta wersja IDE nie jest zainstalowana; zainstalowane: %@", installed.joined(separator: ", "))
        case .ideNotFound: tr("nie znaleziono zainstalowanego IDE tego produktu")
        case .newerThanInstalledIDE(let installed):
            trf("nowsza niż zainstalowane IDE (%@)", installed.joined(separator: ", "))
        case .duplicateApplication, .missingPathEntry, .repeatedPathEntry, .samePlaceAs, .nestedIn, .olderCopyWins, .tccEntry, .tccEntryFileGone,
             .keptInstead, .keptByChoice, .noCopyKept, .versionManagerShim:
            hygieneReasonText(reason, requiredBy: paths)
        }
    }

    /// The `PATH` hygiene, Files and Folders, keep-choice and version-manager shim reasons. The other
    /// reasons are listed rather than defaulted, so a reason added later fails to compile here until
    /// it has a text.
    private static func hygieneReasonText(_ reason: CleanupReason, requiredBy paths: [String]) -> String {
        switch reason {
        case .duplicateApplication: tr("ten sam identyfikator aplikacji w kilku lokalizacjach")
        case .missingPathEntry: tr("ten katalog nie istnieje albo nie jest katalogiem, więc nic w nim nie szukamy")
        case .repeatedPathEntry(let count): trf("ten sam wpis występuje w PATH %@ razy; liczy się pierwszy", "\(count)")
        case .samePlaceAs(let path): trf("to samo miejsce co wcześniejszy wpis %@", path)
        case .nestedIn(let parent): trf("leży wewnątrz katalogu %@, który też jest w PATH", parent)
        case .olderCopyWins(let version, let newer, let newerVersion):
            trf("aktywna jest wersja %@, a przesłonięta kopia %@ ma nowszą wersję %@", version, newer, newerVersion)
        case .tccEntry(let grants, let link):
            tccEntryText(grants: grants, link: link)
        case .tccEntryFileGone(let grants):
            trf("wpis w „Pliki i foldery” (%@) wskazuje plik, którego już nie ma", grantsText(grants))
        case .keptInstead(let path): trf("zostawiasz %@", path)
        case .keptByChoice: tr("tę kopię zostawiasz")
        case .noCopyKept: tr("nie wybrano kopii do zostawienia")
        case .versionManagerShim: tr("shim: uruchamia wersję, którą wskazuje menedżer")
        case .olderVersion, .newerVersion, .shadowedBy, .systemCopy, .managedByApp, .staleSinceBoot, .keptSinceBoot,
             .unknownVersionDirectory, .currentVersion, .protectedLocation, .brokenLink, .requiredBy, .homebrewLeftovers,
             .homebrewKeptVersions, .installedOnlyAsDependency, .recentlyUpgraded, .notRequiredByProjects, .requiredByProjects,
             .unusedGradleDistribution, .unreferencedJDK, .systemJDK, .ideVersionNotInstalled, .ideNotFound, .newerThanInstalledIDE:
            reasonText(reason, requiredBy: paths)
        }
    }

    /// `label` replaces the stored link kind's text, for an entry of a copy the user chose about.
    static func tccEntryText(grants: [CleanupTCCGrant], link: CleanupTCCLink?, label: String? = nil) -> String {
        let entry = trf("wpis w „Pliki i foldery”: %@", grantsText(grants))
        guard let link else { return entry }
        if let label { return "\(entry); \(label)" }
        let kind = switch link.kind {
        case .activeCopy: tr("dotyczy aktywnej kopii")
        case .copyToRemove: tr("dotyczy kopii do usunięcia")
        case .keptCopy: tr("dotyczy kopii, która zostaje")
        case .appManaged(let owner): trf("dotyczy kopii aplikacji %@", owner)
        }
        return "\(entry); \(kind)"
    }

    private static func grantsText(_ grants: [CleanupTCCGrant]) -> String {
        grants.map { grant in
            trf(grant.allowed ? "%@ (zezwolono)" : "%@ (odmówiono)", serviceName(grant.service))
        }.joined(separator: ", ")
    }

    static func serviceName(_ service: CleanupTCCService) -> String {
        switch service {
        case .desktop: tr("Pulpit")
        case .documents: tr("Dokumenty")
        case .downloads: tr("Pobrane")
        case .networkVolumes: tr("woluminy sieciowe")
        case .removableVolumes: tr("woluminy wymienne")
        case .allFiles: tr("Pełny dostęp do dysku")
        }
    }
}
