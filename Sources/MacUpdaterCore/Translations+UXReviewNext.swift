import Foundation

extension Translations {
    /// UX review follow-up of 2026-11-20 — every new Polish-to-English pair of that pass.
    static let uxReviewNext: [String: String] = [
        "%@, ale %@ — sprawdź połączenie i odśwież.": "%@, but %@ — check your connection and refresh.",
        "%@ w kolejce · %@ dokończysz u producenta": "%@ queued · %@ to finish with the developer",
        "Cofnięcie: %@ z %@": "Undo: %@ of %@",
        "Sprawdzam możliwość cofnięcia": "Checking undo availability",
        "Nic nie zaznaczono": "Nothing selected",
        "Zapisano diagnostykę.": "Diagnostics saved.",
        "Nie udało się zapisać diagnostyki: %@. Spróbuj ponownie.": "Couldn't save diagnostics: %@. Try again.",
        "Otwórz szkic e-maila": "Open Email Draft",
        "Otwórz zgłoszenie na GitHubie": "Open Issue on GitHub",
        "Wykryte dane wrażliwe zastąpiłam. Sprawdź podgląd przed wysłaniem.":
            "I replaced the sensitive data I found. Review the preview before sending.",
        "Wykryte dane wrażliwe zastąpiłam znacznikami.": "I replaced the sensitive data I found with placeholders.",
        "Zapisuje paczkę zip z oboma plikami logów i kontekstem środowiska. Wykryte dane wrażliwe zastępuję znacznikami.":
            "Saves a zip with both log files and the environment context. I replace the sensitive data I find with placeholders.",
        "Zaznacz wpisy w logu, jeśli chcesz je dołączyć.": "Select log entries if you want to include them.",
        "Co się działo tuż przed błędem? (opcjonalne)": "What happened just before the error? (optional)",
        "Sprawdzam, czy aplikacje same się aktualizują…": "Checking whether apps update themselves…",
        "Porównuję wersje…": "Comparing versions…",
        "Zaglądam do środka aplikacji…": "Peeking inside the apps…",
        "Węszę w App Store…": "Sniffing around the App Store…",
        "Hau, ta wersja pachnie świeżo!": "Woof, this version smells fresh!",
        "Przenieść %@ do Homebrew?": "Move %@ to Homebrew?",
        "Zrobię kopię obecnej aplikacji, a Homebrew zainstaluje najnowszą wersję w jej miejscu. Jeśli nowa wersja nie przejdzie sprawdzenia podpisu, przywrócę kopię. Zamknij %@ przed kontynuowaniem.":
            "I'll back up the current app, and Homebrew will install the latest version in its place. If the new version fails the signature check, I'll restore the backup. Quit %@ before continuing.",
        "Przenieś": "Move",
        "Wszystko w porządku. Wega nie znalazła uciekinierów.": "All good. Wega found no runaways.",
        "Nie udało mi się zainstalować %@": "I couldn't install %@",
        "Nie udało mi się zainstalować %@. Spróbuj jeszcze raz.": "I couldn't install %@. Try again.",
        "Nie udało mi się zainstalować %@ przez Homebrew.": "I couldn't install %@ through Homebrew.",
        "Przeglądam katalogi z PATH i wersje narzędzi. Niczego nie zmieniam.":
            "Looking through PATH folders and tool versions. I'm not changing anything.",
        "Nowa wersja %@ nie przeszła kontroli, więc przywróciłam poprzednią.":
            "The new version of %@ failed its check, so I restored the previous one.",
        "Nowa wersja %@ nie przeszła kontroli, a poprzedniej nie udało mi się przywrócić.":
            "The new version of %@ failed its check, and I couldn't restore the previous one.",
        "Zainstalowałam %@, ale zmienił się wydawca — sprawdź go.": "I installed %@, but the publisher changed — please check it.",
        "Zmienił się wydawca %@, więc przywróciłam poprzednią wersję.": "The publisher of %@ changed, so I restored the previous version.",
        "Nie udało mi się zaktualizować %@ — na dysku została poprzednia wersja.":
            "I couldn't update %@ — the previous version is still on disk.",
        "Aktualizator %@ podmienił wersję, którą zainstalowałam.": "%@'s own updater replaced the version I installed.",
        "Globalne pakiety npm: %@": "Global npm packages: %@",
        "Producenci: %@ %@": "Vendors: %@ %@",
        "Trwa obchód · %@": "Patrol in progress · %@",
        "do tej pory": "so far",
        "Odświeżam katalog Homebrew…": "Refreshing the Homebrew catalog…",
        "Wega węszy w App Store…": "Wega is sniffing in the App Store…",
        "Wega węszy w npm…": "Wega is sniffing around npm…",
        "Wega węszy u producentów…": "Wega is sniffing at the vendors…",
        "Postęp skanowania": "Scan progress",
        "%@ z %@ źródeł": "%@ of %@ sources",
        "Nie będę proponować aktualizacji %@.": "I won't offer updates for %@.",
        "Pominęłam wersję %@ aplikacji %@. Następną pokażę.": "Skipped version %@ of %@. I'll show the next one.",
        "Ukryte przez Twoje reguły: %@ · Pokaż": "Hidden by your rules: %@ · Show",
        "Przywróć": "Restore",
    ]
}
