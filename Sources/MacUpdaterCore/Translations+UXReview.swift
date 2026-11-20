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
    ]
}
