import Foundation

extension Translations {
    /// Owner decision 2026-11-21 — while the settings sudo reads cannot be trusted, Wega asks for no
    /// administrator password and skips what may need one: the run's rows, the summary's note and
    /// its link to the Touch ID card, the warning above the list and the failure banner.
    static let sudoPromptGate: [String: String] = [
        "pomijam — wymaga hasła": "skipping — needs a password",
        "pominęłam: może potrzebować hasła administratora, a ustawieniom, które czyta sudo, nie można teraz ufać — co zrobić, mówi karta Touch ID w Ustawieniach":
            "skipped: it may need the administrator password, and the settings sudo reads can't be trusted right now — the Touch ID card in Settings says what to do",
        "Otwórz kartę Touch ID": "Open Touch ID card",
    ]
}
