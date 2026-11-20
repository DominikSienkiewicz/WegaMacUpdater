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
    ]
}
