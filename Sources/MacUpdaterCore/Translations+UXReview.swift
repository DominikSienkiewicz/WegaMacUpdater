import Foundation

extension Translations {
    /// UX review of 2026-11-20 — every new Polish-to-English pair of that pass.
    static let uxReview: [String: String] = [
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
        "Aktualizacja odroczona: %@.": "Update postponed: %@.",
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
    ]
}
