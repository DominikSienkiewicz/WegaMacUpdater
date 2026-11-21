import Foundation

extension Translations {
    /// Owner decision 2026-11-21 — while the settings sudo reads cannot be trusted, Wega asks for no
    /// administrator password and skips what may need one: the run's rows, the summary's note and
    /// its link to the Touch ID card, the warning above the list, the readiness card's password row
    /// and the failure banner.
    static let sudoPromptGate: [String: String] = [
        "pomijam — może wymagać hasła": "skipping — may need a password",
        "nie dokończyłam: App Store potrzebował hasła administratora, a ustawieniom, które czyta sudo, nie można teraz ufać — co zrobić, mówi karta Touch ID w Ustawieniach":
            "not finished: the App Store needed the administrator password, and the settings sudo reads can't be trusted right now — the Touch ID card in Settings says what to do",
        "pominęłam: może potrzebować hasła administratora, a ustawieniom, które czyta sudo, nie można teraz ufać — co zrobić, mówi karta Touch ID w Ustawieniach":
            "skipped: it may need the administrator password, and the settings sudo reads can't be trusted right now — the Touch ID card in Settings says what to do",
        "Otwórz kartę Touch ID": "Open Touch ID card",
        "Dopóki ustawieniom, które czyta sudo, nie można ufać, nie poproszę o hasło administratora, więc pominę %@. Co zrobić, mówi karta Touch ID w Ustawieniach.":
            "Until the settings sudo reads can be trusted, I won't ask for the administrator password, so I'll skip %@. The Touch ID card in Settings says what to do.",
        "%@ Cask wymaga hasła administratora, a ustawieniom, które czyta sudo, nie można teraz ufać, więc o nie nie poprosiłam. Co zrobić, mówi karta Touch ID w Ustawieniach.":
            "%@ The cask needs the administrator password, and the settings sudo reads can't be trusted right now, so I didn't ask for it. The Touch ID card in Settings says what to do.",
        "Nie poproszę o hasło administratora, dopóki ustawienia, które czyta sudo, nie zostaną naprawione.":
            "I won't ask for the administrator password until the settings sudo reads are repaired.",
    ]
}
