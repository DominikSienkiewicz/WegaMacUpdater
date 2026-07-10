import Foundation

/// UI languages Wega ships. Polish is the base (the literal strings in the views),
/// English is provided by the translation table in `Translations.swift`.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case pl
    case en

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pl: return "Polski"
        case .en: return "English"
        }
    }

    public var flag: String {
        switch self {
        case .pl: return "🇵🇱"
        case .en: return "🇬🇧"
        }
    }
}

/// The language to start in when the user has never picked one (`wega.language` unset).
///
/// `preferredLanguages` is the ordered list from `Locale.preferredLanguages` — BCP-47
/// tags such as `en-US` or `pl-PL`. The first tag whose language subtag Wega ships wins,
/// which mirrors `Bundle.preferredLocalizations`: a Pole running a German system still
/// gets Polish if it sits above English in System Settings. Anything else — including an
/// empty list — falls back to English, the language the rest of the world reads.
public func defaultLanguage(preferredLanguages: [String]) -> AppLanguage {
    for tag in preferredLanguages {
        let subtag = tag.split(separator: "-").first.map(String.init) ?? tag
        if let language = AppLanguage(rawValue: subtag.lowercased()) {
            return language
        }
    }
    return .en
}
