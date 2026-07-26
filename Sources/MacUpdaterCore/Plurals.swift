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
        )
    ]

    static let en: [String: PluralForms] = [
        "%@ aktualizacji dostępnych": PluralForms(
            one:  "%@ update available",
            few:  "%@ updates available",
            many: "%@ updates available"
        ),
        "i jeszcze %@ aplikacji": PluralForms(
            one:  "and %@ more app",
            few:  "and %@ more apps",
            many: "and %@ more apps"
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
