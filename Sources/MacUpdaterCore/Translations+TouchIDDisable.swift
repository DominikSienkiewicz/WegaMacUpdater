import Foundation

extension Translations {
    /// Turning Touch ID for sudo off from its Settings card (UXP-34).
    static let touchIDDisable: [String: String] = [
        "Pomocnik Wegi działa jako root i umie tylko cztery rzeczy: zainstalować zweryfikowany pakiet Wegi, włączyć albo wyłączyć Touch ID dla sudo, przywrócić kopię aplikacji sprzed aktualizacji, przenieść do Kosza aplikację należącą do roota. Przy każdym połączeniu sprawdza podpis Wegi. Jest opcjonalny.":
            "The Wega helper runs as root and can do only four things: install a verified Wega package, turn Touch ID for sudo on or off, restore an app's pre-update copy, and move a root-owned app to the Trash. It checks Wega's signature on every connection. It is optional.",
        "Zastępuje hasło administratora odciskiem palca w poleceniach sudo, także w Terminalu. Bez niego wpisujesz hasło. Wyłączysz je w karcie Touch ID, gdy pomocnik Wegi jest zainstalowany, albo ręcznie według przewodnika.":
            "Replaces your administrator password with your fingerprint for sudo commands, in Terminal too. Without it, you type the password. Turn it off on the Touch ID card when the Wega helper is installed, or by hand with the user guide.",
        "Wyłącz Touch ID dla sudo": "Turn Off Touch ID for sudo",
        "Bez pomocnika Wegi wyłączysz je ręcznie.": "Without the Wega helper, you turn it off by hand.",
        "Pomocnik Wegi jest nieaktualny albo nie odpowiada. W Ustawieniach usuń go i zainstaluj ponownie albo uruchom Maca ponownie, a wtedy wyłączysz tu Touch ID dla sudo.":
            "The Wega helper is out of date or not answering. In Settings, remove it and install it again, or restart your Mac, and then you can turn off Touch ID for sudo here.",
        "Touch ID dla sudo wyłączone. W nowym oknie Terminala sprawdź „sudo -k; sudo true” — zapyta o hasło.":
            "Touch ID for sudo is off. In a new Terminal window, check “sudo -k; sudo true” — it asks for your password.",
        "Touch ID dla sudo włącza tu linia zapisana inaczej niż dokładna dyrektywa, którą umiem usunąć, więc jej nie zmieniłam. Wyłączysz ją ręcznie według przewodnika.":
            "A line written differently from the exact directive I can remove turns on Touch ID for sudo here, so I left it alone. Turn it off by hand with the user guide.",
        "Touch ID dla sudo jest już wyłączone.": "Touch ID for sudo is already off.",
        "Touch ID dla sudo może wyłączyć tylko administrator zalogowany przy tym Macu.":
            "Only an administrator signed in at this Mac can turn off Touch ID for sudo.",
        "Plik /etc/pam.d/sudo_local wygląda inaczej, niż się spodziewam, więc go nie zmieniłam. Wyłączysz Touch ID ręcznie według przewodnika.":
            "/etc/pam.d/sudo_local doesn't look the way I expect, so I didn't change it. Turn off Touch ID by hand with the user guide.",
        "Plik /etc/pam.d/sudo_local albo katalog /etc/pam.d może zmieniać ktoś poza rootem albo wygląda inaczej, niż powinien. To problem bezpieczeństwa: kto może tam pisać, może dostać uprawnienia roota bez hasła. Nie zmieniłam go. Sprawdź go według przewodnika.":
            "Someone other than root can change /etc/pam.d/sudo_local or the /etc/pam.d directory, or it looks different from what it should. This is a security problem: whoever can write there can get root without a password. I didn't change it. Check it with the user guide.",
        "Po usunięciu tej dyrektywy sudo czytałby też plik %@ — jeśli go nie tworzyłeś, może pozwolić sudo pominąć hasło. Nic nie zmieniłam; sprawdź go według przewodnika.":
            "After removing this directive, sudo would also read %@ — if you didn't create it, it may let sudo skip the password. I changed nothing; check it with the user guide.",
        "Po usunięciu tej dyrektywy sudo czytałby też inny plik ustawień PAM, więc nic nie zmieniłam. Sprawdź przewodnik.":
            "After removing this directive, sudo would also read another PAM settings file, so I changed nothing. Check the user guide.",
        "Plik zmienił się w trakcie mojej pracy, więc zostawiłam go tak, jak go zastałam. Obok może leżeć kopia jego poprzedniej wersji (.sudo_local.wega-swap-… w /etc/pam.d); jak ją sprzątnąć, opisuje przewodnik.":
            "The file changed while I was working, so I left it as I found it. A copy of its previous version may be left next to it (.sudo_local.wega-swap-… in /etc/pam.d); the user guide covers the cleanup.",
        "W pliku są też inne ustawienia sudo, więc go nie zmieniłam. Wyłączysz Touch ID ręcznie według przewodnika.":
            "The file holds other sudo settings too, so I didn't change it. Turn off Touch ID by hand with the user guide.",
        "Zapis się nie udał. Plik jest taki jak przedtem, nic się nie zmieniło.":
            "The write failed. The file is as it was; nothing changed.",
        "Zapis i przywrócenie się nie udały. Poprzedni plik odłożyłam pod %@. Przywróć go według przewodnika.":
            "The write and the restore both failed. I set the previous file aside at %@. Restore it with the user guide.",
        "Pomocnik Wegi nie odpowiedział, a Touch ID dla sudo jest nadal włączone. Spróbuj ponownie albo wyłącz je ręcznie według przewodnika.":
            "The Wega helper didn't answer, and Touch ID for sudo is still on. Try again, or turn it off by hand with the user guide.",
        "Katalog %@ może zmieniać ktoś poza rootem. Gdy Touch ID dla sudo jest wyłączone, sudo czyta też ustawienia z tego miejsca, więc program działający na Twoim koncie mógłby tam dodać takie, które pozwolą sudo pominąć hasło. Zajrzyj do przewodnika.":
            "Someone other than root can change the directory %@. With Touch ID for sudo off, sudo also reads settings from there, so a program running as you could add settings that let sudo skip the password. See the user guide.",
    ]
}
