import Foundation

extension Translations {
    /// UX next batch of 2026-11-21 — every new Polish-to-English pair of that pass.
    static let uxNextBatch: [String: String] = [
        "czeka": "waiting",
        "instaluję…": "installing…",
        "zainstalowano, sprawdzam": "installed, checking",
        "nie udało się": "failed",
        "nie zacznę": "won't start",
        "w toku": "in progress",
        "u producenta": "with the vendor",
        "Trwa aktualizacja · od %@": "Updating · since %@",
        "Bieżącej instalacji nie przerywam w połowie.": "I never stop an install halfway.",
        "Do końca aktualizacji lista jest zablokowana.": "The list stays locked until the update ends.",
        "skan niepełny":
            "check incomplete",
        "Wymaga Twojego działania":
            "Needs your action",
        "producenci":
            "vendors",
        "Homebrew nie pilnuje wersji tych aplikacji (auto_updates) — robią to same. Wega sprawdza je u źródła.":
            "Homebrew doesn't track these apps' versions (auto_updates) — they update themselves. Wega checks them at the source.",
        "Czy ta aplikacja żyje poza Homebrew?":
            "Does this app live outside Homebrew?",
        "%@: zmienił się podpis producenta (%@ → %@). Zaufaj nowemu podpisowi tylko wtedy, gdy producent zmienił konto.":
            "%@: the developer signature changed (%@ → %@). Trust the new signature only if the developer changed accounts.",
        "%@: zmienił się podpis producenta (%@ → %@). Przywróciłam poprzednią zaufaną wersję.":
            "%@: the developer signature changed (%@ → %@). I restored the previous trusted version.",
        "%@: zmienił się podpis producenta — przywróciłam poprzednią zaufaną wersję.":
            "%@: the developer signature changed — I restored the previous trusted version.",
        "Zmienił się podpis producenta: %@. Sprawdź to w Wedze.":
            "Developer signature changed: %@. Check it in Wega.",
        "Teraz podpisuje ją identyfikator zespołu %@ zamiast zaufanego %@. Potwierdź tylko, jeśli wiesz, że producent zmienił konto deweloperskie.":
            "It is now signed with team identifier %@ instead of the trusted %@. Confirm only if you know the developer changed accounts.",
        "%@: aplikację podpisano ponownie innym podpisem producenta (%@ zamiast %@). Zaufania nie zmieniłam.":
            "%@: the app was re-signed with a different developer signature (%@ instead of %@). I didn't change the trust.",
        "%@: ufam teraz nowemu podpisowi producenta (%@).":
            "%@: I now trust the new developer signature (%@).",
        "%@: zainstalowana aplikacja ma zaufany podpis producenta.":
            "%@: the installed app has the trusted developer signature.",
    ]
}
