import Foundation
import MacUpdaterCore

/// What Wega says after asking the helper to turn Touch ID for sudo on: calm, first person, and always
/// the next step. `isEnabled` is the state read from the file after the helper answered, not the
/// helper's claim (RC2-2). The texts both directions share come from `TouchIDDisableCopy`.
enum TouchIDEnableCopy {
    static var outdatedHelper: String {
        tr("Pomocnik Wegi jest nieaktualny albo nie odpowiada, więc nie włączy Touch ID dla sudo. Użyj polecenia niżej albo w Ustawieniach usuń pomocnika i zainstaluj go ponownie (albo uruchom Maca ponownie).")
    }

    /// RC2-7, Z12: the only advice while the settings `sudo` reads may not be root's alone, because a
    /// password typed into `sudo` could reach a module someone added there.
    static var recoveryOnly: String {
        tr("Nie wpisuj hasła do sudo, dopóki tego nie naprawisz — także gdy Wega poprosi o nie przy aktualizacji: sudo czyta te ustawienia. Napraw je z trybu odzyskiwania według przewodnika.")
    }

    static func line(for result: TouchIDSudoEnableResult, isEnabled: Bool) -> String {
        switch result {
        case .enabled, .alreadyEnabled:
            guard isEnabled else {
                return tr("Zapisałam plik, ale Touch ID dla sudo nadal nie wygląda na włączone. Sprawdź /etc/pam.d/sudo_local według przewodnika.")
            }
            return tr("Touch ID podpięty pod sudo.")
        case .refused(let refusal):
            return line(for: refusal)
        case .restoredAfterFailure:
            return TouchIDDisableCopy.line(for: .restoredAfterFailure, stillEnabled: false)
        case .rollbackFailed(let backupPath?):
            return TouchIDDisableCopy.line(for: .rollbackFailed(backupPath: backupPath), stillEnabled: false)
        case .rollbackFailed(nil):
            return tr("Zapis się nie udał i nie wiem, w jakim stanie jest plik /etc/pam.d/sudo_local. Sprawdź go według przewodnika.")
        }
    }

    /// −4 or −5, whether the helper or the app's own look saw it: what is wrong, then recoveryOS only.
    static func unsafePolicyNote(_ refusal: TouchIDSudoDisableRefusal) -> String {
        let condition = refusal == .notRegularFile
            ? tr("Plik /etc/pam.d/sudo_local nie jest zwykłym plikiem, więc go nie zmieniłam. sudo może przez niego czytać ustawienia spoza /etc/pam.d.")
            : TouchIDDisableCopy.line(for: .refused(.unsafeOwnership), stillEnabled: false)
        return condition + " " + recoveryOnly
    }

    private static func line(for refusal: TouchIDSudoEnableRefusal) -> String {
        switch refusal {
        case .noConsoleUser, .callerNotConsoleUser, .callerNotAdministrator:
            return tr("Touch ID dla sudo może włączyć tylko administrator zalogowany przy tym Macu.")
        case .notRegularFile:
            return unsafePolicyNote(.notRegularFile)
        case .unsafeOwnership:
            return unsafePolicyNote(.unsafeOwnership)
        case .tooLarge, .unreadable:
            return tr("Plik /etc/pam.d/sudo_local wygląda inaczej, niż się spodziewam, więc go nie zmieniłam. Włączysz Touch ID ręcznie według przewodnika.")
        case .changedDuringOperation:
            return TouchIDDisableCopy.line(for: .refused(.changedDuringOperation), stillEnabled: false)
        }
    }
}
