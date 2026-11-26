import Foundation

/// UX-08 — plural engine behind `trp(base, count)`.
///
/// The flat `Translations` dictionary carries one hard form per message, so a counter
/// built with `trf` read „1 aktualizacji dostępnych" (and „1 updates available") — wrong
/// in both languages. This file adds the grammatical-number variants and the rule that
/// picks between them.

/// Grammatical-number category for a count. Polish distinguishes three forms; English
/// collapses `few` and `many` into a single plural, so for English messages those two
/// variants are identical and the Polish rule below selects the correct one either way.
public enum PluralCategory: Sendable, Equatable {
    case one
    case few
    case many
}

/// Polish plural rule for `count`:
///   • `one`  — exactly 1
///   • `few`  — a count ending in 2–4, except the 12–14 exception
///   • `many` — everything else (including 0 and 12–14)
/// The sign is ignored, so a negative count categorises like its magnitude.
public func polishPluralCategory(_ count: Int) -> PluralCategory {
    let n = abs(count)
    if n == 1 { return .one }
    let lastDigit = n % 10
    let lastTwoDigits = n % 100
    if (2...4).contains(lastDigit) && !(12...14).contains(lastTwoDigits) {
        return .few
    }
    return .many
}

/// The three variant templates for one pluralisable message. Each keeps the `%@`
/// placeholder that the count is formatted into. For English `few` and `many` hold the
/// same plural string.
public struct PluralForms: Sendable, Equatable {
    public let one: String
    public let few: String
    public let many: String

    public init(one: String, few: String, many: String) {
        self.one = one
        self.few = few
        self.many = many
    }

    public func form(for category: PluralCategory) -> String {
        switch category {
        case .one:  return one
        case .few:  return few
        case .many: return many
        }
    }
}

/// Pluralisable UI messages, keyed by the Polish base string — the same key convention as
/// `Translations`. Each language supplies its own one/few/many templates; a base with no
/// entry has no plural forms, and callers fall back to the flat `Translations` lookup.
public enum Plurals {
    public static func forms(_ base: String, language: AppLanguage) -> PluralForms? {
        switch language {
        case .pl: return pl[base]
        case .en: return en[base]
        }
    }

    static let pl: [String: PluralForms] = [
        "Skan zakończony: %@ aktualizacji.": PluralForms(
            one:  "Skan zakończony: %@ aktualizacja.",
            few:  "Skan zakończony: %@ aktualizacje.",
            many: "Skan zakończony: %@ aktualizacji."
        ),
        "Odinstalowano %@ aplikacji": PluralForms(
            one:  "Odinstalowano %@ aplikację",
            few:  "Odinstalowano %@ aplikacje",
            many: "Odinstalowano %@ aplikacji"
        ),
        "Odinstalowano %@ aplikacji.": PluralForms(
            one:  "Odinstalowano %@ aplikację.",
            few:  "Odinstalowano %@ aplikacje.",
            many: "Odinstalowano %@ aplikacji."
        ),
        "%@ aktualizacji dostępnych": PluralForms(
            one:  "%@ aktualizacja dostępna",
            few:  "%@ aktualizacje dostępne",
            many: "%@ aktualizacji dostępnych"
        ),
        // UX-11g — trailing summary when the dropdown caps the named app list.
        "i jeszcze %@ aplikacji": PluralForms(
            one:  "i jeszcze %@ aplikacja",
            few:  "i jeszcze %@ aplikacje",
            many: "i jeszcze %@ aplikacji"
        ),
        // C2 band headline.
        "%@ aktualizacji": PluralForms(
            one:  "%@ aktualizacja",
            few:  "%@ aktualizacje",
            many: "%@ aktualizacji"
        ),
        // UXP-13 — the band's vendor count; "z" takes the genitive plural for every count.
        "z %@ aplikacji": PluralForms(
            one:  "z %@ aplikacji",
            few:  "z %@ aplikacji",
            many: "z %@ aplikacji"
        ),
        "%@ z możliwą poprawką bezp.": PluralForms(
            one:  "%@ z możliwą poprawką bezp.",
            few:  "%@ z możliwą poprawką bezp.",
            many: "%@ z możliwą poprawką bezp."
        ),
        "Notatki %@ wydań wspominają o bezpieczeństwie.": PluralForms(
            one:  "Notatki jednego wydania wspominają o bezpieczeństwie.",
            few:  "Notatki %@ wydań wspominają o bezpieczeństwie.",
            many: "Notatki %@ wydań wspominają o bezpieczeństwie."
        ),
        "Usuń %@ aplikacji": PluralForms(
            one:  "Usuń %@ aplikację",
            few:  "Usuń %@ aplikacje",
            many: "Usuń %@ aplikacji"
        ),
        "trwale wyczyść dane %@ pakietów Homebrew": PluralForms(
            one:  "trwale wyczyść dane %@ pakietu Homebrew",
            few:  "trwale wyczyść dane %@ pakietów Homebrew",
            many: "trwale wyczyść dane %@ pakietów Homebrew"
        ),
        "i przenieś %@ pozycji do Kosza": PluralForms(
            one:  "i przenieś %@ pozycję do Kosza",
            few:  "i przenieś %@ pozycje do Kosza",
            many: "i przenieś %@ pozycji do Kosza"
        ),
        // UXP-05 — notification body: the apps beyond the two that are named.
        "i %@ innych": PluralForms(
            one:  "i %@ inna",
            few:  "i %@ inne",
            many: "i %@ innych"
        ),
        "W tle zaktualizowałam %@ aplikacji.": PluralForms(
            one:  "W tle zaktualizowałam %@ aplikację.",
            few:  "W tle zaktualizowałam %@ aplikacje.",
            many: "W tle zaktualizowałam %@ aplikacji."
        ),
        "Zaktualizować %@ pozycji?": PluralForms(
            one:  "Zaktualizować %@ pozycję?",
            few:  "Zaktualizować %@ pozycje?",
            many: "Zaktualizować %@ pozycji?"
        ),
        "Zaktualizowano %@ pakietów": PluralForms(
            one:  "Zaktualizowano %@ pakiet",
            few:  "Zaktualizowano %@ pakiety",
            many: "Zaktualizowano %@ pakietów"
        ),
        "Gotowe! %@ pakietów odświeżonych.": PluralForms(
            one:  "Gotowe! %@ pakiet odświeżony.",
            few:  "Gotowe! %@ pakiety odświeżone.",
            many: "Gotowe! %@ pakietów odświeżonych."
        ),
        "%@ casków bez aplikacji": PluralForms(
            one:  "%@ cask bez aplikacji",
            few:  "%@ caski bez aplikacji",
            many: "%@ casków bez aplikacji"
        ),
        "Usunięto %@ nieaktualnych casków": PluralForms(
            one:  "Usunięto %@ nieaktualny cask",
            few:  "Usunięto %@ nieaktualne caski",
            many: "Usunięto %@ nieaktualnych casków"
        ),
        "Homebrew nadal śledzi %@ casków bez aplikacji — szczegóły są w logach.": PluralForms(
            one:  "Homebrew nadal śledzi %@ cask bez aplikacji — szczegóły są w logach.",
            few:  "Homebrew nadal śledzi %@ caski bez aplikacji — szczegóły są w logach.",
            many: "Homebrew nadal śledzi %@ casków bez aplikacji — szczegóły są w logach."
        ),
        "%@ resztek do Kosza": PluralForms(
            one:  "%@ resztka do Kosza",
            few:  "%@ resztki do Kosza",
            many: "%@ resztek do Kosza"
        ),
        "Pominięto %@ aplikacji — powody poniżej.": PluralForms(
            one:  "Pominięto %@ aplikację — powody poniżej.",
            few:  "Pominięto %@ aplikacje — powody poniżej.",
            many: "Pominięto %@ aplikacji — powody poniżej."
        ),
        "Nie udało się przenieść %@ resztek do Kosza.": PluralForms(
            one:  "Nie udało się przenieść %@ resztkę do Kosza.",
            few:  "Nie udało się przenieść %@ resztki do Kosza.",
            many: "Nie udało się przenieść %@ resztek do Kosza."
        ),
        "%@ aplikacji": PluralForms(
            one:  "%@ aplikacja",
            few:  "%@ aplikacje",
            many: "%@ aplikacji"
        ),
        "odinstalowanie %@ aplikacji": PluralForms(
            one:  "odinstalowanie %@ aplikacji",
            few:  "odinstalowanie %@ aplikacji",
            many: "odinstalowanie %@ aplikacji"
        ),
        "Odinstalować %@ aplikacji?": PluralForms(
            one:  "Odinstalować %@ aplikację?",
            few:  "Odinstalować %@ aplikacje?",
            many: "Odinstalować %@ aplikacji?"
        ),
        "%@ aplikacji nie jest zarządzanych przez Homebrew — trafią do Kosza.": PluralForms(
            one:  "%@ aplikacja nie jest zarządzana przez Homebrew — trafi do Kosza.",
            few:  "%@ aplikacje nie są zarządzane przez Homebrew — trafią do Kosza.",
            many: "%@ aplikacji nie jest zarządzanych przez Homebrew — trafią do Kosza."
        ),
        "Obchód skończony — %@ aplikacji pod opieką.": PluralForms(
            one:  "Obchód skończony — %@ aplikacja pod opieką.",
            few:  "Obchód skończony — %@ aplikacje pod opieką.",
            many: "Obchód skończony — %@ aplikacji pod opieką."
        ),
        "Zwęszyłam %@ aplikacji do przeniesienia do Homebrew.": PluralForms(
            one:  "Zwęszyłam %@ aplikację do przeniesienia do Homebrew.",
            few:  "Zwęszyłam %@ aplikacje do przeniesienia do Homebrew.",
            many: "Zwęszyłam %@ aplikacji do przeniesienia do Homebrew."
        ),
        "Zeskanowano /Applications · znalazłam %@ aplikacji poza zarządzaniem": PluralForms(
            one:  "Zeskanowano /Applications · znalazłam %@ aplikację poza zarządzaniem",
            few:  "Zeskanowano /Applications · znalazłam %@ aplikacje poza zarządzaniem",
            many: "Zeskanowano /Applications · znalazłam %@ aplikacji poza zarządzaniem"
        ),
        "Znalazłam %@ rzeczy do uporządkowania.": PluralForms(
            one:  "Znalazłam %@ rzecz do uporządkowania.",
            few:  "Znalazłam %@ rzeczy do uporządkowania.",
            many: "Znalazłam %@ rzeczy do uporządkowania."
        ),
        "Znalazłam %@ aktualizacji": PluralForms(
            one:  "Znalazłam %@ aktualizację",
            few:  "Znalazłam %@ aktualizacje",
            many: "Znalazłam %@ aktualizacji"
        ),
        "%@ źródeł nie odpowiedziało": PluralForms(
            one:  "%@ źródło nie odpowiedziało",
            few:  "%@ źródła nie odpowiedziały",
            many: "%@ źródeł nie odpowiedziało"
        ),
        "Pominięto %@ najstarszych wpisów": PluralForms(
            one:  "Pominięto %@ najstarszy wpis",
            few:  "Pominięto %@ najstarsze wpisy",
            many: "Pominięto %@ najstarszych wpisów"
        ),
        "…i %@ wcześniejszych wydań": PluralForms(
            one:  "…i %@ wcześniejsze wydanie",
            few:  "…i %@ wcześniejsze wydania",
            many: "…i %@ wcześniejszych wydań"
        ),
        "%@ wyników do przejrzenia": PluralForms(
            one: "%@ wynik do przejrzenia", few: "%@ wyniki do przejrzenia", many: "%@ wyników do przejrzenia"
        ),
        "Bez akcji: %@ narzędzi": PluralForms(
            one:  "Bez akcji: %@ narzędzie",
            few:  "Bez akcji: %@ narzędzia",
            many: "Bez akcji: %@ narzędzi"
        ),
        "Bez akcji: %@ pozycji": PluralForms(
            one:  "Bez akcji: %@ pozycja",
            few:  "Bez akcji: %@ pozycje",
            many: "Bez akcji: %@ pozycji"
        ),
        "%@ poleceń": PluralForms(
            one:  "%@ polecenie",
            few:  "%@ polecenia",
            many: "%@ poleceń"
        )
    ]

    static let en: [String: PluralForms] = [
        "Skan zakończony: %@ aktualizacji.": PluralForms(
            one:  "Scan finished: %@ update.",
            few:  "Scan finished: %@ updates.",
            many: "Scan finished: %@ updates."
        ),
        "Odinstalowano %@ aplikacji": PluralForms(
            one:  "Uninstalled %@ app",
            few:  "Uninstalled %@ apps",
            many: "Uninstalled %@ apps"
        ),
        "Odinstalowano %@ aplikacji.": PluralForms(
            one:  "Uninstalled %@ app.",
            few:  "Uninstalled %@ apps.",
            many: "Uninstalled %@ apps."
        ),
        "%@ aktualizacji dostępnych": PluralForms(
            one:  "%@ update available",
            few:  "%@ updates available",
            many: "%@ updates available"
        ),
        "i jeszcze %@ aplikacji": PluralForms(
            one:  "and %@ more app",
            few:  "and %@ more apps",
            many: "and %@ more apps"
        ),
        "%@ aktualizacji": PluralForms(
            one:  "%@ update",
            few:  "%@ updates",
            many: "%@ updates"
        ),
        "z %@ aplikacji": PluralForms(
            one:  "of %@ app",
            few:  "of %@ apps",
            many: "of %@ apps"
        ),
        "%@ z możliwą poprawką bezp.": PluralForms(
            one:  "%@ may fix a security issue",
            few:  "%@ may fix security issues",
            many: "%@ may fix security issues"
        ),
        "Notatki %@ wydań wspominają o bezpieczeństwie.": PluralForms(
            one:  "One release note mentions security.",
            few:  "%@ release notes mention security.",
            many: "%@ release notes mention security."
        ),
        "Usuń %@ aplikacji": PluralForms(
            one:  "Remove %@ app",
            few:  "Remove %@ apps",
            many: "Remove %@ apps"
        ),
        "trwale wyczyść dane %@ pakietów Homebrew": PluralForms(
            one:  "permanently clear data for %@ Homebrew package",
            few:  "permanently clear data for %@ Homebrew packages",
            many: "permanently clear data for %@ Homebrew packages"
        ),
        "i przenieś %@ pozycji do Kosza": PluralForms(
            one:  "and move %@ item to Trash",
            few:  "and move %@ items to Trash",
            many: "and move %@ items to Trash"
        ),
        "i %@ innych": PluralForms(
            one:  "and %@ more",
            few:  "and %@ more",
            many: "and %@ more"
        ),
        "W tle zaktualizowałam %@ aplikacji.": PluralForms(
            one:  "I updated %@ app in the background.",
            few:  "I updated %@ apps in the background.",
            many: "I updated %@ apps in the background."
        ),
        "Zaktualizować %@ pozycji?": PluralForms(
            one:  "Update %@ item?",
            few:  "Update %@ items?",
            many: "Update %@ items?"
        ),
        "Zaktualizowano %@ pakietów": PluralForms(
            one:  "Updated %@ package",
            few:  "Updated %@ packages",
            many: "Updated %@ packages"
        ),
        "Gotowe! %@ pakietów odświeżonych.": PluralForms(
            one:  "Done! %@ package refreshed.",
            few:  "Done! %@ packages refreshed.",
            many: "Done! %@ packages refreshed."
        ),
        "%@ casków bez aplikacji": PluralForms(
            one:  "%@ cask with no app",
            few:  "%@ casks with no app",
            many: "%@ casks with no app"
        ),
        "Usunięto %@ nieaktualnych casków": PluralForms(
            one:  "Removed %@ stale cask",
            few:  "Removed %@ stale casks",
            many: "Removed %@ stale casks"
        ),
        "Homebrew nadal śledzi %@ casków bez aplikacji — szczegóły są w logach.": PluralForms(
            one:  "Homebrew still tracks %@ cask with no app — see the log for details.",
            few:  "Homebrew still tracks %@ casks with no app — see the log for details.",
            many: "Homebrew still tracks %@ casks with no app — see the log for details."
        ),
        "%@ resztek do Kosza": PluralForms(
            one:  "%@ leftover to Trash",
            few:  "%@ leftovers to Trash",
            many: "%@ leftovers to Trash"
        ),
        "Pominięto %@ aplikacji — powody poniżej.": PluralForms(
            one:  "Skipped %@ app — reasons below.",
            few:  "Skipped %@ apps — reasons below.",
            many: "Skipped %@ apps — reasons below."
        ),
        "Nie udało się przenieść %@ resztek do Kosza.": PluralForms(
            one:  "Could not move %@ leftover to the Trash.",
            few:  "Could not move %@ leftovers to the Trash.",
            many: "Could not move %@ leftovers to the Trash."
        ),
        "%@ aplikacji": PluralForms(
            one:  "%@ app",
            few:  "%@ apps",
            many: "%@ apps"
        ),
        "odinstalowanie %@ aplikacji": PluralForms(
            one:  "uninstalling %@ app",
            few:  "uninstalling %@ apps",
            many: "uninstalling %@ apps"
        ),
        "Odinstalować %@ aplikacji?": PluralForms(
            one:  "Uninstall %@ app?",
            few:  "Uninstall %@ apps?",
            many: "Uninstall %@ apps?"
        ),
        "%@ aplikacji nie jest zarządzanych przez Homebrew — trafią do Kosza.": PluralForms(
            one:  "%@ app isn't managed by Homebrew — it will go to the Trash.",
            few:  "%@ apps aren't managed by Homebrew — they will go to the Trash.",
            many: "%@ apps aren't managed by Homebrew — they will go to the Trash."
        ),
        "Obchód skończony — %@ aplikacji pod opieką.": PluralForms(
            one:  "Patrol complete — %@ app under watch.",
            few:  "Patrol complete — %@ apps under watch.",
            many: "Patrol complete — %@ apps under watch."
        ),
        "Zwęszyłam %@ aplikacji do przeniesienia do Homebrew.": PluralForms(
            one:  "I sniffed out %@ app to move to Homebrew.",
            few:  "I sniffed out %@ apps to move to Homebrew.",
            many: "I sniffed out %@ apps to move to Homebrew."
        ),
        "Zeskanowano /Applications · znalazłam %@ aplikacji poza zarządzaniem": PluralForms(
            one:  "Scanned /Applications · found %@ app outside management",
            few:  "Scanned /Applications · found %@ apps outside management",
            many: "Scanned /Applications · found %@ apps outside management"
        ),
        "Znalazłam %@ rzeczy do uporządkowania.": PluralForms(
            one:  "I found %@ thing to tidy up.",
            few:  "I found %@ things to tidy up.",
            many: "I found %@ things to tidy up."
        ),
        "Znalazłam %@ aktualizacji": PluralForms(
            one:  "I found %@ update",
            few:  "I found %@ updates",
            many: "I found %@ updates"
        ),
        "%@ źródeł nie odpowiedziało": PluralForms(
            one:  "%@ source didn't respond",
            few:  "%@ sources didn't respond",
            many: "%@ sources didn't respond"
        ),
        "Pominięto %@ najstarszych wpisów": PluralForms(
            one:  "%@ oldest entry omitted",
            few:  "%@ oldest entries omitted",
            many: "%@ oldest entries omitted"
        ),
        "…i %@ wcześniejszych wydań": PluralForms(
            one:  "…and %@ earlier release",
            few:  "…and %@ earlier releases",
            many: "…and %@ earlier releases"
        ),
        "%@ wyników do przejrzenia": PluralForms(
            one: "%@ result to review", few: "%@ results to review", many: "%@ results to review"
        ),
        "Bez akcji: %@ narzędzi": PluralForms(
            one:  "No action: %@ tool",
            few:  "No action: %@ tools",
            many: "No action: %@ tools"
        ),
        "Bez akcji: %@ pozycji": PluralForms(
            one:  "No action: %@ item",
            few:  "No action: %@ items",
            many: "No action: %@ items"
        ),
        "%@ poleceń": PluralForms(
            one:  "%@ command",
            few:  "%@ commands",
            many: "%@ commands"
        )
    ]
}

/// Grammatically-correct rendering of a pluralisable message for `count` in `language`,
/// with the count formatted into the `%@` placeholder. Returns `nil` when `base` has no
/// registered plural forms, so the caller can decide how to degrade.
public func pluralize(_ base: String, count: Int, language: AppLanguage) -> String? {
    guard let forms = Plurals.forms(base, language: language) else { return nil }
    let template = forms.form(for: polishPluralCategory(count))
    return String(format: template, "\(count)")
}
