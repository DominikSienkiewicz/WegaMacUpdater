import Foundation
import MacUpdaterCore

/// What Wega says about turning Touch ID for sudo off: calm, first person, and always the next step.
/// `stillEnabled` is the state read from the file after the helper answered, not the helper's claim.
enum TouchIDDisableCopy {
    static var outdatedHelper: String {
        tr("Pomocnik Wegi jest nieaktualny albo nie odpowiada. W Ustawieniach usuń go i zainstaluj ponownie albo uruchom Maca ponownie, a wtedy wyłączysz tu Touch ID dla sudo.")
    }

    /// `fallbackPath` is shown only when it is a policy path the app itself knows.
    static func line(for result: TouchIDSudoDisableResult, stillEnabled: Bool, fallbackPath: String? = nil) -> String {
        switch result {
        case .removed:
            return stillEnabled ? unchangedLine : removedLine
        case .nothingToRemove:
            return stillEnabled ? unchangedLine : tr("Touch ID dla sudo jest już wyłączone.")
        case .refused(let refusal):
            return line(for: refusal, fallbackPath: fallbackPath)
        case .restoredAfterFailure:
            return tr("Zapis się nie udał. Plik jest taki jak przedtem, nic się nie zmieniło.")
        case .rollbackFailed(let backupPath):
            return trf("Zapis i przywrócenie się nie udały. Poprzedni plik odłożyłam pod %@. Przywróć go według przewodnika.", backupPath)
        }
    }

    /// No answer does not mean nothing changed: the file was read again, so a removal shows as one.
    static func afterHelperError(stillEnabled: Bool) -> String {
        if !stillEnabled { return removedLine }
        return tr("Pomocnik Wegi nie odpowiedział, a Touch ID dla sudo jest nadal włączone. Spróbuj ponownie albo wyłącz je ręcznie według przewodnika.")
    }

    static func localDirectoryWarning(path: String) -> String {
        trf("Katalog %@ może zmieniać ktoś poza rootem. Gdy Touch ID dla sudo jest wyłączone, sudo czyta też ustawienia z tego miejsca, więc program działający na Twoim koncie mógłby tam dodać takie, które pozwolą sudo pominąć hasło. Zajrzyj do przewodnika.", path)
    }

    private static var removedLine: String {
        tr("Touch ID dla sudo wyłączone. W nowym oknie Terminala sprawdź „sudo -k; sudo true” — zapyta o hasło.")
    }

    /// A line the helper cannot remove: it is not worded as a claim about who wrote it.
    private static var unchangedLine: String {
        tr("Touch ID dla sudo włącza tu linia zapisana inaczej niż dokładna dyrektywa, którą umiem usunąć, więc jej nie zmieniłam. Wyłączysz ją ręcznie według przewodnika.")
    }

    private static func line(for refusal: TouchIDSudoDisableRefusal, fallbackPath: String?) -> String {
        switch refusal {
        case .noConsoleUser, .callerNotConsoleUser, .callerNotAdministrator:
            return tr("Touch ID dla sudo może wyłączyć tylko administrator zalogowany przy tym Macu.")
        case .tooLarge, .unreadable, .lineContinuation:
            return tr("Plik /etc/pam.d/sudo_local wygląda inaczej, niż się spodziewam, więc go nie zmieniłam. Wyłączysz Touch ID ręcznie według przewodnika.")
        case .notRegularFile, .unsafeOwnership:
            // RC2-7: `sudo` reads this file, so the manual route through `sudo` is no advice here.
            return TouchIDEnableCopy.unsafePolicyNote(refusal)
        case .fallbackPolicyPresent:
            guard let fallbackPath, TouchIDSudoDisabler.fallbackPolicyPaths.contains(fallbackPath) else {
                return tr("Po usunięciu tej dyrektywy sudo czytałby też inny plik ustawień PAM, więc nic nie zmieniłam. Sprawdź przewodnik.")
            }
            return trf("Po usunięciu tej dyrektywy sudo czytałby też plik %@ — jeśli go nie tworzyłeś, może pozwolić sudo pominąć hasło. Nic nie zmieniłam; sprawdź go według przewodnika.", fallbackPath)
        case .changedDuringOperation:
            return tr("Plik zmienił się w trakcie mojej pracy, więc go nie ruszyłam. Spróbuj jeszcze raz.")
        case .otherDirectivesPresent:
            return tr("W pliku są też inne ustawienia sudo, więc go nie zmieniłam. Wyłączysz Touch ID ręcznie według przewodnika.")
        }
    }
}
