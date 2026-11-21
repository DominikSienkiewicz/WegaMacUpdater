import MacUpdaterCore

/// UX-06 — the four operation states of a self-update, kept distinct so none is described by
/// another's copy. Downloading, opening a downloaded installer for the user to finish, a
/// completed headless install, and a failure that opens the release page instead.
enum SelfUpdateOperationState {
    case downloading
    case opened
    case installed
    case failed
}

/// The self-update button label and per-state messages. Every string here is localized;
/// the underlying technical error (download/verify failure) stays in the log, never in these
/// user-facing lines.
enum SelfUpdatePresentation {
    /// The button label, honest about whether the click installs or only downloads+opens.
    static func actionLabel(_ action: SelfUpdateAction) -> String {
        switch action {
        case .install:         return tr("Pobierz i zainstaluj")
        case .downloadAndOpen: return tr("Pobierz i otwórz instalator")
        }
    }

    /// The user-facing message for one operation state.
    static func message(for state: SelfUpdateOperationState) -> String {
        switch state {
        case .downloading: return tr("Pobieram nową wersję Wegi…")
        case .opened:      return tr("Pobrałam aktualizację — zamknij Wegę, zanim ją zastąpisz.")
        case .installed:   return tr("Aktualizacja zainstalowana — uruchom Wegę ponownie, żeby jej użyć.")
        case .failed:      return tr("Nie udało się pobrać aktualizacji — otwieram stronę wydania.")
        }
    }

    /// The line under "Nie potwierdzono zakończenia instalacji". A copy that fails the bundle gate
    /// (Z14) gets no helper, so it can neither check the installation nor settle it, and the line
    /// sends the user to the copy installed from the .pkg.
    static func uncertainInstallationDetail(fromRefusedCopy: Bool) -> String {
        fromRefusedCopy
            ? openInstalledCopy
            : tr("Instalator może nadal działać. Dalsze zmiany są zablokowane; nie uruchamiaj drugiego instalatora.")
    }

    static var openInstalledCopy: String {
        tr("Ta kopia Wegi nie może używać pomocnika, więc nie sprawdzi tej instalacji. Zakończ ją i otwórz Wegę zainstalowaną z pakietu .pkg w folderze /Applications. Do tego czasu dalsze zmiany są zablokowane.")
    }
}
