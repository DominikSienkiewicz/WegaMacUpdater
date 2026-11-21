import Foundation

extension Translations {
    /// UX review, remaining proposals of 2026-11-21 — every new Polish-to-English pair of that pass.
    static let uxReviewRest: [String: String] = [
        "katalog Homebrew sprzed %@ min": "Homebrew catalog from %@ min ago",
        "Pomocnik Wegi":
            "Wega helper",
        "Zainstaluj pomocnika":
            "Install Helper",
        "Usuń pomocnika":
            "Remove Helper",
        "Pomocnik Wegi jest gotowy.":
            "The Wega helper is ready.",
        "Potwierdź usunięcie pomocnika Wegi":
            "Confirm removing the Wega helper",
        "wymaga pomocnika Wegi — włącz go w Ustawieniach.":
            "needs the Wega helper — turn it on in Settings.",
        "pomocnik Wegi usunie ją bez hasła":
            "the Wega helper will remove it without a password",
        "pomocnik Wegi jest nieaktualny lub nie odpowiada — w Ustawieniach usuń go i zainstaluj ponownie.":
            "the Wega helper is outdated or not responding — in Settings, remove it and install it again.",
        "%@ do Kosza przez pomocnika Wegi":
            "%@ to Trash via the Wega helper",
        "Pomocnik Wegi nie potwierdził usunięcia — aplikacja mogła już opuścić /Applications. Odświeżona lista pokazuje, czy nadal tam jest.":
            "The Wega helper did not confirm the removal — the app may already have left /Applications. The refreshed list shows whether it is still there.",
        "Do Homebrew":
            "To Homebrew",
        "Przenieś do Homebrew":
            "Move to Homebrew",
        "Przenieś %@ do Homebrew":
            "Move %@ to Homebrew",
        "Aplikacje Homebrew":
            "Homebrew apps",
        "Narzędzia Homebrew":
            "Homebrew tools",
        "Aplikacja Homebrew":
            "Homebrew app",
        "Narzędzie Homebrew":
            "Homebrew tool",
        "Usuń nieużywane źródła pakietów":
            "Remove Unused Package Sources",
        "Usunięto nieużywane źródła pakietów":
            "Removed unused package sources",
        "Homebrew pomija pakiety z niezaufanych źródeł (tapów)":
            "Homebrew is skipping packages from untrusted sources (taps)",
        "Nie udało się zmienić źródeł Homebrew":
            "Couldn't change the Homebrew sources",
        "Warunki aktualizacji":
            "Update conditions",
        "Wstrzymane aktualizacje":
            "Paused updates",
        "Ukryte przez Twoją regułę":
            "Hidden by your rule",
        "Brak reguł. Na liście aktualizacji otwórz „Więcej działań” przy aplikacji.":
            "No rules. In the update list, open “More actions” for an app.",
        "Przywróciłam %@ do wersji %@. Nie będę proponować nowszych, dopóki tego nie zmienisz w Ustawieniach → Sprawdzanie i tło → Wstrzymane aktualizacje.":
            "I restored %@ to version %@. I won't offer newer versions until you change that in Settings → Checking & Background → Paused updates.",
        "Nie udało się cofnąć aktualizacji":
            "Couldn't undo the update",
        "Nie udało się zrobić kopii sprzed aktualizacji: %@.":
            "Couldn't make a pre-update copy of %@.",
        "Nie udało się zrobić kopii zapasowej przed aktualizacją. Sprawdź wolne miejsce na dysku i spróbuj ponownie.":
            "Couldn't back up the app before updating. Check free disk space and try again.",
        "Przed zrobieniem kopii sprzed aktualizacji i pobraniem Wega sprawdza miejsce, łącze, baterię i temperaturę.":
            "Before making a pre-update copy and downloading, Wega checks disk space, network, battery and temperature.",
        "Po aktualizacji Wega na chwilę uruchamia aplikację w tle i sprawdza, czy nie zamyka się od razu. Jeśli tak, wraca poprzednia wersja.":
            "After an update, Wega briefly starts the app in the background and checks it doesn't quit right away. If it does, the previous version comes back.",
        "Przed każdą aktualizacją Wega ponownie sprawdza, czy aplikacja nie działa, nie jest zignorowana lub przypięta oraz czy da się zrobić kopię sprzed aktualizacji.":
            "Before every update, Wega checks again that the app is not running, ignored or pinned, and that a pre-update copy can be made.",
        "Status każdego pakietu uwzględnia bieżącą aktualizację, reguły i uruchomioną aplikację. Kopia sprzed aktualizacji, zasoby i podpis producenta są sprawdzane dopiero bezpośrednio przed aktualizacją.":
            "Each package status includes its current update, rules and running app. The pre-update copy, resources and developer signature are checked only immediately before an update.",
        "Nie mogę znaleźć zainstalowanej aplikacji .app potrzebnej do kopii sprzed aktualizacji i sprawdzenia wyniku.":
            "I can't find the installed .app needed for the pre-update copy and the result check.",
        "Ten cask nie instaluje aplikacji .app, więc nie zrobię kopii sprzed aktualizacji ani nie sprawdzę wyniku.":
            "This cask doesn't install an .app, so I can't make a pre-update copy or check the result.",
        "Producent (podpis)":
            "Developer (signature)",
        "Podpis producenta się zmienił:":
            "Developer signature changed:",
        "pierwsze sprawdzenie podpisu":
            "first signature check",
        "podpis bez zmian":
            "signature unchanged",
        "Zmienił się podpis producenta":
            "Developer signature changed",
        "Zaufaj nowemu podpisowi":
            "Trust the New Signature",
        "Zaufano nowemu podpisowi":
            "New signature trusted",
        "Ten podpis już jest zaufany":
            "Signature already trusted",
        "Zaufać nowemu podpisowi aplikacji %@?":
            "Trust the new signature of %@?",
        "Zobacz u producenta":
            "See at the developer",
        "%@: podpis producenta już przed aktualizacją różnił się od zaufanego (%@ → %@). Aktualizację zablokowałam. Zaufaj nowemu podpisowi tylko wtedy, gdy producent zmienił konto.":
            "%@: the developer signature already differed from the trusted one (%@ → %@). I blocked the update. Trust the new signature only if the developer changed accounts.",
        "Bez automatycznego cofnięcia — poprzednią wersję pobierzesz od producenta.":
            "No automatic undo — download the previous version from the developer.",
        "Przeniesie do Kosza — możesz przywrócić, dopóki go nie opróżnisz.":
            "Moves to the Trash — you can restore it until you empty the Trash.",
        "Uruchomi polecenie Homebrew — Wega tego nie cofnie.":
            "Runs a Homebrew command — Wega can't undo it.",
        "Tylko kopiuje polecenie; nic teraz nie usuwa.":
            "Only copies the command; nothing is removed now.",
        "Nie udało się zaktualizować: %@. Spróbuj jeszcze raz; jeśli to się powtórzy, otwórz Logi.":
            "Couldn't update: %@. Try again; if it happens again, open Logs.",
        "Homebrew zgłosił błąd. Spróbuj jeszcze raz; jeśli to się powtórzy, otwórz Logi.":
            "Homebrew reported an error. Try again; if it happens again, open Logs.",
        "Nie zaktualizowałam: %@ — macOS potrzebuje Twojej zgody.":
            "Couldn't update: %@ — macOS needs your permission.",
        "Nie zaktualizowałam części pakietów — macOS potrzebuje Twojej zgody.":
            "Couldn't update some packages — macOS needs your permission.",
        "Pokaż w logach":
            "Show in Logs",
        "Pokaż wszystkie":
            "Show All",
        "Ogólne":
            "General",
        "Sprawdzanie i tło":
            "Checking & Background",
        "Uprawnienia i prywatność":
            "Permissions & Privacy",
        "Zaawansowane":
            "Advanced",
        "Zatwierdź pomocnika w Ustawieniach systemowych → Elementy logowania, potem wróć tutaj.":
            "Approve the helper in System Settings → Login Items, then come back here.",
        "Zapas na rozpakowanie":
            "Unpacking headroom",
        "Zapas wolnego miejsca":
            "Free-space buffer",
        "Głębokość podfolderów":
            "Subfolder depth",
        "Opcjonalny token zmniejsza przerwy przez limity zapytań GitHuba. Jest w pęku kluczy.":
            "An optional token reduces interruptions from GitHub request limits. It is kept in the Keychain.",
        "Wega skanuje /Applications, ~/Applications i ich podfoldery. Dodaj własne katalogi (także na innych wolumenach), pomiń te, których nie chcesz przeszukiwać, i ustaw głębokość podfolderów.":
            "Wega scans /Applications, ~/Applications and their subfolders. Add your own directories (including on other volumes), skip the ones you don't want searched, and set the subfolder depth.",
        "Co Wega robi": "What Wega does",
        "Uprawnienia": "Permissions",
        "Połączenia": "Connections",
        "Dane lokalne i raporty": "Local data and reports",
        "Bez niego Wega poprosi o hasło. Wyłączysz go przyciskiem „Usuń pomocnika”.":
            "Without it, Wega asks for your password. Switch it off with “Remove Helper”.",
        "Touch ID dla poleceń administratora": "Touch ID for administrator commands",
        "Zastępuje hasło administratora odciskiem palca w poleceniach sudo, także w Terminalu. Bez niego wpisujesz hasło. Jak je wyłączyć, opisuje przewodnik.":
            "Replaces your administrator password with your fingerprint for sudo commands, in Terminal too. Without it, you type the password. The user guide explains how to turn it off.",
        "macOS pyta o nie, gdy Wega podmienia aplikację w /Applications. Bez niego aktualizacje aplikacji się nie udadzą. Zmienisz to w Ustawieniach systemowych → Prywatność i bezpieczeństwo.":
            "macOS asks for it when Wega replaces an app in /Applications. Without it, app updates fail. Change it in System Settings → Privacy & Security.",
        "Nie znam jeszcze stanu uprawnienia Zarządzanie aplikacjami.":
            "App Management permission status is not known yet.",
        "Potrzebny tylko mapie „Pliki i foldery” w Porządkach; dostają go też procesy uruchamiane przez Wegę. Bez niego mapa jest niepełna. Odbierzesz go w Ustawieniach systemowych → Prywatność i bezpieczeństwo.":
            "Needed only by the “Files and folders” map in Cleanup; processes Wega starts get it too. Without it, the map is incomplete. Revoke it in System Settings → Privacy & Security.",
        "Sprawdzanie aktualizacji niczego nie instaluje ani nie usuwa — odświeża tylko katalog Homebrew. Wyjątek to aplikacje, którym pozwolisz aktualizować się w tle.":
            "Checking for updates installs and removes nothing — it only refreshes Homebrew's catalog. The exception is apps you allow to update in the background.",
        "Wega nie wysyła nic o Tobie: nie ma telemetrii ani analityki.":
            "Wega sends nothing about you: no telemetry, no analytics.",
        "Producentom wysyła tylko to, czego wymaga sprawdzenie, np. numer zainstalowanej wersji.":
            "To developers it sends only what a check needs, such as the installed version number.",
        "Łączy się z GitHubem (katalog aplikacji, aktualizacje Wegi), producentami zainstalowanych aplikacji, Homebrew i App Store.":
            "It connects to GitHub (app catalog, Wega updates), the developers of apps you have installed, Homebrew and the App Store.",
        "Pokaż stałe adresy": "Show Fixed Addresses",
        "Do tego adresy aktualizacji zapisane w zainstalowanych aplikacjach, rejestr npm i serwery App Store.":
            "Plus the update addresses stored in your installed apps, the npm registry and App Store servers.",
        "Stan: %@": "Status: %@",
        "Wega łączy się z tymi adresami albo otwiera je w przeglądarce, gdy o to poprosisz.":
            "Wega connects to these addresses, or opens them in your browser when you ask it to.",
        "Logi, ostatni wynik skanu i kopie sprzed aktualizacji (do 7 dni) zostają na tym Macu.":
            "Logs, the last scan result and pre-update copies (kept up to 7 days) stay on this Mac.",
        "Raport błędu przejrzysz przed otwarciem poczty albo GitHuba.":
            "You can review a problem report before opening email or GitHub.",
        "Działa też w Terminalu, nie tylko w Wedze.": "Also works in Terminal, not just in Wega.",
        "Używaj Touch ID zamiast hasła administratora": "Use Touch ID Instead of Your Admin Password",
        "Polecenia administratora potwierdzasz odciskiem palca zamiast hasła — także aktualizacje casków, które o nie proszą.":
            "You confirm administrator commands with your fingerprint instead of your password — including cask updates that ask for it.",
        "Po włączeniu Homebrew poprosi o odcisk palca zamiast hasła. Włączenie raz wymaga uprawnień administratora.":
            "Once on, Homebrew asks for your fingerprint instead of your password. Turning it on needs administrator rights once.",
        "Sprawdzono wczoraj, %@": "Checked yesterday, %@",
        "dziś, %@": "today, %@",
        "wczoraj, %@": "yesterday, %@",
        "jutro, %@": "tomorrow, %@",
        "Kolejna próba: %@, gdy Wega jest uruchomiona. Zamknięcie okna nie kończy aplikacji.":
            "Next attempt: %@, while Wega is running. Closing the window doesn't quit the app.",
        "Sprawdź i zaktualizuj w tle (%@)": "Check and update in background (%@)",
        "Otwórz Wegę": "Open Wega",
        "Zakończ Wegę": "Quit Wega",
        "aktualizacja %@ do %@": "update %@ to %@",
        "z automatycznym cofnięciem": "can be undone automatically",
        "bez automatycznego cofnięcia": "can't be undone automatically",
        "w kolejce": "queued",
        "poza kolejką": "not queued",
        "Spacja dodaje do kolejki, Return pokazuje szczegóły.": "Space adds to the queue, Return shows details.",
        "Spacja usuwa z kolejki, Return pokazuje szczegóły.": "Space removes from the queue, Return shows details.",
        "Kolejka: %@": "Queue: %@",
        "Więcej działań dla %@": "More actions for %@",
        "Aktualizacje: %@": "Updates: %@",
        "Aktualizacje: %@, w tym %@ z możliwą poprawką bezpieczeństwa": "Updates: %@, %@ may fix security issues",
        "Usuń regułę dla %@": "Remove rule for %@",
        "Przywróć %@": "Restore %@",
        "Odczytano %@": "Read %@",
        "Odśwież spis": "Refresh Inventory",
        "Nie sprawdza nowych wersji": "Does not check for new versions",
        "Żadna aplikacja nie pasuje do tych filtrów.": "No apps match these filters.",
        "Wyczyść filtry": "Clear Filters",
        "Nie znalazłam aplikacji w wybranych folderach. Sprawdź katalogi skanowania albo odśwież spis.":
            "I found no apps in the selected folders. Check the scan folders or refresh the inventory.",
    ]
}
