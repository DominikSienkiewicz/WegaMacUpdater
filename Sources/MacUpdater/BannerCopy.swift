import Foundation
import MacUpdaterCore

enum BannerCopy {
    struct FailureText: Equatable { let message: String; let fullMessage: String? }

    /// At most three names; more read "A, B i N inne" and carry the full list.
    static func names(_ names: [String]) -> (short: String, full: String?) {
        guard names.count > 3 else { return (names.joined(separator: ", "), nil) }
        let short = names.prefix(2).joined(separator: ", ") + " " + trp("i %@ innych", names.count - 2)
        return (short, names.joined(separator: ", "))
    }

    static func updateFailed(names: [String]) -> FailureText {
        guard !names.isEmpty else {
            return FailureText(
                message: tr("Homebrew zgłosił błąd. Spróbuj jeszcze raz; jeśli to się powtórzy, otwórz Logi."),
                fullMessage: nil)
        }
        let template = "Nie udało się zaktualizować: %@. Spróbuj jeszcze raz; jeśli to się powtórzy, otwórz Logi."
        let (short, full) = Self.names(names)
        return FailureText(message: trf(template, short), fullMessage: full.map { trf(template, $0) })
    }
}
