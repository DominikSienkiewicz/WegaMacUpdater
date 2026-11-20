import Foundation

extension Translations {
    /// UX review of 2026-11-20 — every new Polish-to-English pair of that pass.
    static let uxReview: [String: String] = [
        "Zatrzymaj po rozpoczętych instalacjach": "Stop After Active Installs",
        "Kończę rozpoczęte instalacje, nowych nie zaczynam": "Finishing active installs, not starting new ones",
        "Aktualizacja w toku, %@ z %@": "Update in progress, %@ of %@",
        "Aktualizuję %@ z %@…": "Updating %@ of %@…",
        "Nowe aktualizacje:": "New updates:",
        "Wega znalazła w notatkach: %@": "Found in the release notes: %@",
        "Ta kopia Wegi nie umie poprosić o hasło administratora, więc %@ się nie zaktualizuje. Zainstaluj Wegę z pliku .pkg albo włącz Touch ID.":
            "This copy of Wega can't ask for your administrator password, so %@ won't update. Install Wega from the .pkg or turn on Touch ID.",
        "Pobierz .pkg": "Download .pkg",
        "Zanim zaktualizuję pierwszą aplikację": "Before I update your first app",
        "Sprawdzanie działa bez żadnych uprawnień.": "Checking works without any permissions.",
        "Podmiana aplikacji w /Applications — macOS musi na to pozwolić.":
            "Replacing apps in /Applications — macOS has to allow it.",
        "Część aplikacji prosi przy aktualizacji o hasło administratora.":
            "Some apps ask for your administrator password when they update.",
        "Później": "Later",
        "Wszystko jasne": "Got it",
        "Co robi pomocnik?": "What does the helper do?",
        "Powiadamiać o nowych aktualizacjach?": "Notify you about new updates?",
        "Pomocnik Wegi działa jako root i umie tylko cztery rzeczy: zainstalować zweryfikowany pakiet Wegi, włączyć Touch ID dla sudo, przywrócić kopię aplikacji sprzed aktualizacji, przenieść do Kosza aplikację należącą do roota. Przy każdym połączeniu sprawdza podpis Wegi. Jest opcjonalny.":
            "The Wega helper runs as root and can do only four things: install a verified Wega package, turn on Touch ID for sudo, restore an app's pre-update copy, and move a root-owned app to the Trash. It checks Wega's signature on every connection. It is optional.",
        "Nie włączaj powiadomień": "Keep Notifications Off",
        "Możesz je włączyć później w Ustawieniach Wegi.": "You can turn them on later in Wega Settings.",
        "Powiadomienia": "Notifications",
        "Powiadamiaj o nowych aktualizacjach": "Notify me about new updates",
        "Otwórz ustawienia powiadomień": "Open Notification Settings",
        "sprawdzanie niepełne": "check incomplete",
        "sprawdzenie niepełne": "check incomplete",
        "Część źródeł milczy — nie wiem, czy to wszystko.":
            "Some sources stayed quiet — I can't tell if that's everything.",
        "Nie mogę cofnąć aktualizacji": "I can't undo the update",
        "Nie mogę cofnąć %@: kopia sprzed aktualizacji już nie istnieje.":
            "I can't undo %@: the pre-update copy no longer exists.",
        "Nie mogę cofnąć %@: aplikacji nie ma już w tym miejscu.":
            "I can't undo %@: the app is no longer where it was.",
        "Przywróciłam %@ do wersji %@. Nie będę proponować nowszych, dopóki tego nie zmienisz w Ustawieniach → Ignorowane i przypięte.":
            "I restored %@ to version %@. I won't offer newer versions until you change that in Settings → Ignored & pinned.",
        "Dla aktualizacji aplikacji z Homebrew, które to obsługują, Wega trzyma kopię poprzedniej aplikacji przez 7 dni. Kopia nie obejmuje danych aplikacji. Teraz żadna kopia nie czeka.":
            "For supported Homebrew app updates, Wega keeps the previous app for 7 days. The copy does not include app data. No copy is waiting right now.",
        "Odkładam pobieranie": "Postponing the download",
        "Aktualizacja odroczona: %@": "Update postponed: %@",
        "To połączenie ma ograniczony transfer. Użyj innej sieci albo zmień Warunki aktualizacji.":
            "This connection has limited data. Use another network or change Update conditions.",
        "Włączony jest tryb oszczędzania danych. Wyłącz go albo użyj innej sieci.":
            "Low Data Mode is on. Turn it off or use another network.",
        "Mac jest zbyt gorący. Poczekaj, aż ostygnie.": "Your Mac is too hot. Wait for it to cool down.",
        "Niski poziom baterii. Podłącz zasilanie i spróbuj ponownie.":
            "Battery is low. Connect power and try again.",
        "Nie mogę odczytać wolnego miejsca. Spróbuj ponownie; jeśli to wróci, otwórz Logi.":
            "I can't read the free disk space. Try again; if it happens again, open Logs.",
        "Za mało miejsca: potrzeba około %@. Zwolnij miejsce i spróbuj ponownie.":
            "Not enough space: about %@ is needed. Free up space and try again.",
        "suma zostanie sprawdzona": "checksum will be checked",
        "źródło nie podaje sumy do sprawdzenia": "the source provides no checksum to verify",
        "Do Kosza: %@": "To Trash: %@",
        "Homebrew: %@": "Homebrew: %@",
        "(resztki z zap nie trafiają do Kosza)": "(zap leftovers don't go to the Trash)",
        "Do Kosza: %@ · Homebrew: %@ (resztki z zap nie trafiają do Kosza)":
            "To Trash: %@ · Homebrew: %@ (zap leftovers don't go to the Trash)",
        "%@ nie chce się zamknąć.": "%@ won't quit.",
        "Wymuszenie może stracić niezapisaną pracę.": "Forcing it may lose unsaved work.",
        "Zostaw otwartą": "Leave It Open",
        "Nie udało się zamknąć aplikacji": "Couldn't quit the app",
        "Nie mogę zamknąć %@. Zamknij ją ręcznie.": "I can't quit %@. Quit it yourself.",
        "Sprawdzanie niepełne.": "Check incomplete.",
        "Aktualizacja zakończona: %@ z %@.": "Update finished: %@ of %@.",
        "%@ wymaga uwagi.": "%@ needs attention.",
        "%@ wymagają uwagi.": "%@ need attention.",
        "Aktualizacja zatrzymana: zaktualizowano %@ z %@.": "Update stopped: %@ of %@ updated.",
        "Nic nie odinstalowano. Szczegóły są na liście wyników.":
            "Nothing was uninstalled. Details are in the results list.",
    ]
}
