import Foundation

extension Translations {
    /// C2 stage 4 — the after-update summary: the notes of its rows, the band's check and its
    /// summary ("Nie udało się: %@" already exists elsewhere and is reused).
    static let runSummary: [String: String] = [
        "kopia do %@": "backup until %@",
        "bez cofnięcia": "no undo",
        "cofnięto do %@": "undone to %@",
        "nie udało się — szczegóły w logu": "failed — details in the log",
        "nadal nieaktualna po sprawdzeniu": "still outdated after the check",
        "nowa wersja nie przeszła kontroli — przywróciłam poprzednią": "the new version failed its check — I restored the previous one",
        "zainstalowano, ale sprawdzenie nie potwierdziło wyniku": "installed, but the check could not confirm it",
        "zatrzymano przed startem": "stopped before it started",
        "nie uruchomiłam — szczegóły w logu": "not started — details in the log",
        "Sprawdzam wynik · %@": "Checking the result · %@",
        "Odświeżam listę…": "Refreshing the list…",
        "Wynik pokażę po sprawdzeniu.": "I'll show the result after the check.",
        "Zaktualizowano %@ z %@": "Updated %@ of %@",
        "Zaktualizowano: %@": "Updated: %@",
        "Cofnięto: %@": "Rolled back: %@",
        "Bez potwierdzenia: %@": "Not confirmed: %@",
        "Nie zaczęłam: %@": "Not started: %@",
        "U producenta: %@": "With the developer: %@",
        "Zamknij podsumowanie": "Close summary",
        "Wynik aktualizacji": "Update result",
    ]
}
