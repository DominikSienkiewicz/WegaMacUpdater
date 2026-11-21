import Foundation

extension Translations {
    /// UX follow-up batch of 2026-11-21 — every new Polish-to-English pair of that pass.
    static let uxFollowup: [String: String] = [
        "Skan niepełny": "Check incomplete",
        "Aktualizacja; skan niepełny": "Update available; check incomplete",
        "Skan niepełny.": "Check incomplete.",
        "Zgłoś aplikację ›": "Report app ›",
        // Turning Touch ID for sudo on through the helper (Aneks E.6, E.9).
        "Touch ID dla sudo może włączyć tylko administrator zalogowany przy tym Macu.":
            "Only an administrator signed in at this Mac can turn on Touch ID for sudo.",
        "Plik /etc/pam.d/sudo_local wygląda inaczej, niż się spodziewam, więc go nie zmieniłam. Sprawdź go według przewodnika.":
            "/etc/pam.d/sudo_local doesn't look the way I expect, so I didn't change it. Check it with the user guide.",
        "Plik /etc/pam.d/sudo_local nie jest zwykłym plikiem, więc go nie zmieniłam. sudo może przez niego czytać ustawienia spoza /etc/pam.d.":
            "/etc/pam.d/sudo_local isn't a regular file, so I didn't change it. Through it, sudo may read settings from outside /etc/pam.d.",
        "Nie wpisuj hasła do sudo, dopóki tego nie naprawisz — także gdy Wega poprosi o nie przy aktualizacji: sudo czyta te ustawienia. Napraw je z trybu odzyskiwania według przewodnika.":
            "Don't type your password into sudo until you fix this — not even when Wega asks for it during an update: sudo reads these settings. Fix them from macOS Recovery with the user guide.",
        "Nie wiem, w jakim stanie jest teraz plik /etc/pam.d/sudo_local: zapis albo jego sprawdzenie się nie udało. Sprawdź go według przewodnika.":
            "I don't know what state /etc/pam.d/sudo_local is in now: writing it or checking the write failed. Check it with the user guide.",
        // The sudo routes closed (RC2-6, E.9); Wega's own line under the card's note (M2).
        "Nie włączyłam Touch ID dla sudo: ustawienia, które czyta sudo, nie są bezpieczne.":
            "I didn't turn on Touch ID for sudo: the settings sudo reads aren't safe.",
        "Nie wyłączyłam Touch ID dla sudo: ustawienia, które czyta sudo, nie są bezpieczne.":
            "I didn't turn off Touch ID for sudo: the settings sudo reads aren't safe.",
        "Plik /etc/pam.d/sudo może zmieniać ktoś poza rootem. To problem bezpieczeństwa: kto może tam pisać, może dostać uprawnienia roota bez hasła.":
            "Someone other than root can change /etc/pam.d/sudo. This is a security problem: whoever can write there can get root without a password.",
        "Nie mogę sprawdzić, czy ustawienia sudo w /etc/pam.d są bezpieczne, więc nie podaję polecenia ani przycisku.":
            "I can't check whether the sudo settings in /etc/pam.d are safe, so I'm not offering a command or a button.",
        "Zapisałam plik, ale Touch ID dla sudo nadal nie wygląda na włączone. Sprawdź /etc/pam.d/sudo_local według przewodnika.":
            "I wrote the file, but Touch ID for sudo still doesn't look turned on. Check /etc/pam.d/sudo_local with the user guide.",
        "Pomocnik Wegi jest nieaktualny albo nie odpowiada, więc nie włączy Touch ID dla sudo. Użyj polecenia niżej albo w Ustawieniach usuń pomocnika i zainstaluj go ponownie (albo uruchom Maca ponownie).":
            "The Wega helper is out of date or not answering, so it won't turn on Touch ID for sudo. Use the command below, or in Settings remove the helper and install it again (or restart your Mac).",
        "Pomocnik Wegi jest nieaktualny albo nie odpowiada, więc nie włączy Touch ID dla sudo. W Ustawieniach usuń pomocnika i zainstaluj go ponownie albo uruchom Maca ponownie.":
            "The Wega helper is out of date or not answering, so it won't turn on Touch ID for sudo. In Settings, remove the helper and install it again, or restart your Mac.",
        "Plik /etc/pam.d/sudo_local ma już linię z Touch ID, więc niczego nie zapisałam, ale nie widzę, żeby Touch ID dla sudo było włączone. Sprawdź plik według przewodnika.":
            "/etc/pam.d/sudo_local already has a Touch ID line, so I didn't write anything, but I can't see Touch ID for sudo turned on. Check the file with the user guide.",
    ]
}
