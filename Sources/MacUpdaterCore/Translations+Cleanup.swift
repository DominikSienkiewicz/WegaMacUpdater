import Foundation

extension Translations {
    static let cleanup: [String: String] = [
        "Porządki": "Cleanup",
        "Duplikaty i pozostałości": "Duplicates and leftovers",
        "Posprzątam po aktualizacjach.": "I'll tidy up after updates.",

        // Destination header, banners and empty states
        "Odczytaj PATH": "Read PATH",
        "Skanuj": "Scan",
        "Skanuję…": "Scanning…",
        "Odczytuję PATH z powłoki…": "Reading PATH from the shell…",
        "Usuwam…": "Removing…",
        "przybliżony": "approximate",
        "z powłoki %@, %@": "from the %@ shell, %@",
        "Odczyt ma ponad 7 dni — odczytaj PATH ponownie.": "The read is over 7 days old — read PATH again.",
        "Do odzyskania: %@ bezpiecznie · %@ wymaga decyzji": "Reclaimable: %@ safely · %@ needs a decision",
        "Wynik skanu z %@": "Scan result from %@",
        "Odczytać PATH z powłoki?": "Read PATH from the shell?",
        "Wega raz uruchomi konfigurację Twojej powłoki (np. ~/.zshrc), żeby odczytać PATH. Jeśli teraz pojawi się jakieś pytanie lub okno, pochodzi ono z tej konfiguracji, nie z Wegi. Zapisana zostanie tylko lista katalogów PATH.":
            "Wega will run your shell configuration (such as ~/.zshrc) once to read PATH. If a question or a window appears now, it comes from that configuration, not from Wega. Only the list of PATH directories is saved.",
        "Powłoka %@ nie jest obsługiwana, więc PATH nie został odczytany. Skan użyje poprzedniego odczytu albo przybliżonego PATH.":
            "The %@ shell is not supported, so PATH was not read. The scan uses the previous read or the approximate PATH.",
        "Nie udało się odczytać PATH z powłoki. Skan użyje poprzedniego odczytu albo przybliżonego PATH.":
            "PATH could not be read from the shell. The scan uses the previous read or the approximate PATH.",
        "Skan nie powiódł się. Poprzedni wynik, jeśli był, zostaje na ekranie.": "The scan failed. The previous result, if any, stays on screen.",
        "Raport tekstowy…": "Text report…",
        "Raport JSON…": "JSON report…",
        "Zapisz raport jako tekst lub JSON, ze ścieżkami w postaci ~": "Save the report as text or JSON, with paths written as ~",
        "Przeglądam katalogi z PATH, katalogi wersji i stan powłok. Niczego nie zmieniam.":
            "Looking through the PATH directories, version directories and shell state. Nothing is changed.",
        "Wega sprawdzi, które narzędzia masz w kilku kopiach i co zostało po aktualizacjach. Nic nie zniknie bez Twojego potwierdzenia.":
            "Wega checks which tools you have in several copies and what updates left behind. Nothing disappears without your confirmation.",
        "Węszę po katalogach z narzędziami…": "Sniffing through the tool directories…",
        "Skan się nie udał.": "The scan didn't work out.",
        "Gotowe. Zobacz, co mogę posprzątać.": "Done. See what I can tidy up.",

        // Sections
        "Wiele kopii tego samego narzędzia": "Several copies of the same tool",
        "Stan powłok": "Shell state",
        "Pominięte lokalizacje chronione": "Skipped protected locations",
        "Wpisy w „Pliki i foldery”": "Entries in “Files and Folders”",
        "Nie znaleziono kopii ani starych wersji narzędzi.": "No duplicate copies or old tool versions found.",
        "Nie znaleziono pozostałości po sesjach powłoki.": "No leftovers from shell sessions found.",
        "PATH jest %@, więc to, która kopia jest aktywna, może się różnić od Terminala. Odczytaj PATH z powłoki, żeby to potwierdzić.":
            "PATH is %@, so which copy is active may differ from Terminal. Read PATH from the shell to confirm it.",
        "Narzędzie wiersza poleceń nie ma pakietu aplikacji, więc macOS zapisuje zgodę na dostęp do plików osobno dla każdej ścieżki, z której zostało uruchomione.":
            "A command-line tool has no app bundle, so macOS records file-access consent separately for every path it was run from.",
        "Każda kopia z sekcji „Wiele kopii tego samego narzędzia” może mieć w Ustawieniach systemowych → Prywatność i ochrona → Pliki i foldery własny wpis.":
            "Every copy under “Several copies of the same tool” may have its own entry in System Settings → Privacy & Security → Files and Folders.",
        "Mapa, która przypisze te wpisy do konkretnych kopii, pojawi się w kolejnej wersji jako opcja w Ustawieniach.":
            "A map that matches these entries to specific copies will arrive in a later version as an option in Settings.",

        // Rows
        "tylko informacja": "information only",
        "wersja nieznana": "version unknown",
        "używa: %@": "in use by: %@",
        "Do Kosza…": "Move to Trash…",
        "Odinstaluj…": "Uninstall…",

        // Statuses
        "aktywna": "active",
        "przesłonięta": "shadowed",
        "nieużywana": "unused",
        "nieaktualny": "stale",
        "w użyciu": "in use",
        "oczekiwana": "expected",
        "zarządzana przez aplikację": "managed by an app",
        "zależność": "dependency",
        "uszkodzone dowiązanie": "broken link",
        "pominięta (lokalizacja chroniona)": "skipped (protected location)",
        "informacja": "information",

        // Reasons
        "starsza wersja; bieżąca to %@": "older version; the current one is %@",
        "nowsza wersja; bieżąca to %@": "newer version; the current one is %@",
        "przesłania ją %@, wcześniej w PATH": "shadowed by %@, earlier in PATH",
        "kopia dostarczana z macOS": "a copy that ships with macOS",
        "aktualizuje ją aplikacja %@": "kept up to date by the %@ app",
        "wpisy sprzed ostatniego uruchomienia systemu: %@": "entries from before the last restart: %@",
        "wpisy z bieżącego uruchomienia, zostają: %@": "entries from the current session, kept: %@",
        "katalog wersji, którego układu Wega nie zna": "a version directory whose layout Wega does not know",
        "bieżąca wersja": "the current version",
        "lokalizacja chroniona — Wega jej nie odczytuje": "a protected location — Wega does not read it",
        "dowiązanie wskazuje nieistniejący plik": "the link points to a missing file",
        "potrzebna formułom: %@": "needed by the formulae: %@",

        // Instructions
        "Usuń ją narzędziem, które ją zainstalowało.": "Remove it with the tool that installed it.",
        "Dowiązanie %@ prowadzi do aplikacji; usuń je ręcznie, z uprawnieniami administratora.":
            "The link %@ leads into an app; remove it by hand, with administrator rights.",

        // Detector notes
        "Homebrew jest niedostępny, więc Wega nie sprawdziła, czy inne formuły zależą od przesłoniętych kopii. Te kopie nie mają akcji usunięcia.":
            "Homebrew is unavailable, so Wega did not check whether other formulae depend on the shadowed copies. Those copies offer no removal.",
        "Sprawdzenie zależności Homebrew nie powiodło się. Formuły, których nie sprawdzono, nie mają akcji usunięcia.":
            "The Homebrew dependency check failed. Formulae it did not check offer no removal.",
        "Ta część skanu nie powiodła się: %@. Jej wyników nie ma w raporcie.": "This part of the scan failed: %@. Its results are not in the report.",
        "kopie w PATH": "copies in PATH",
        "źródła kopii": "copy sources",
        "katalogi wersji": "version directories",
        "zależności Homebrew": "Homebrew dependencies",
        "stan powłok": "shell state",

        // Sources
        "formuła Homebrew %@": "Homebrew formula %@",
        "cask Homebrew %@": "Homebrew cask %@",
        "z aplikacji %@": "from the %@ app",
        "kopia aplikacji %@": "copy owned by the %@ app",
        "menedżer wersji %@": "version manager %@",
        "menedżer pakietów %@": "package manager %@",
        "własny instalator %@": "%@'s own installer",
        "kopia systemowa": "system copy",
        "samodzielna kopia": "standalone copy",

        // Confirmation sheet
        "Potwierdź usunięcie": "Confirm removal",
        "Rozmiar": "Size",
        "Powód": "Reason",
        "Działanie": "Action",
        "nieznany": "unknown",
        "Ryzyko: %@": "Risk: %@",
        "niskie": "low",
        "średnie": "medium",
        "wysokie": "high",
        "Przeniesienie do Kosza: %@": "Move to the Trash: %@",
        "Przeniesienie do Kosza — liczba wpisów: %@, folder: %@": "Move to the Trash — entries: %@, folder: %@",
        "Używane podczas skanu przez": "In use during the scan by",
        "Ten element jest teraz używany przez:": "This item is now in use by:",
        "Rozumiem, że te procesy mogą przestać działać poprawnie. Usuń mimo to.":
            "I understand these processes may stop working correctly. Remove anyway.",

        // Removal outcomes
        "Usunięto. Wega odświeża wynik.": "Removed. Wega is refreshing the result.",
        "Tego elementu Wega nie usuwa sama — skorzystaj z polecenia lub wskazówki przy nim.":
            "Wega does not remove this item itself — use the command or the hint next to it.",
        "Ten element zmienił się od skanu, więc niczego nie ruszono. Kliknij „Skanuj” i spróbuj ponownie.":
            "This item changed since the scan, so nothing was touched. Click “Scan” and try again.",
        "Niczego nie usunięto: tej formuły potrzebują teraz %@.": "Nothing was removed: %@ now need this formula.",
        "Usunięcie nie powiodło się (%@). Uruchom skan, żeby zobaczyć bieżący stan.": "The removal failed (%@). Run a scan to see the current state.",

        // Export
        "raport-porządków": "cleanup-report",
        "Porządki — raport z %@": "Cleanup — report from %@",
        "Uwagi skanu:": "Scan notes:",
        "Uwagi skanu: brak": "Scan notes: none",
        "Pominięte lokalizacje chronione: brak": "Skipped protected locations: none",
    ]
}
