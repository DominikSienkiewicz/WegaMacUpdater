import Foundation
import Combine
import MacUpdaterCore

/// Backing store read by the free `tr(_:)` function from any context. Mirrors the
/// manager's current language so string lookup needs no actor hop. Written only on
/// the main thread (from the manager), read on the main thread (view bodies).
enum LocalizedStrings {
    // DEBT-04: język trzymany za zamkiem zamiast `nonisolated(unsafe)` — bezpieczny
    // odczyt/zapis z dowolnego kontekstu (uncontended NSLock ~ns, bez wpływu na tr()).
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var current: AppLanguage = .pl
    }
    private static let storage = Storage()

    static var current: AppLanguage {
        get { storage.lock.withLock { storage.current } }
        set { storage.lock.withLock { storage.current = newValue } }
    }

    static func translate(_ base: String) -> String {
        switch current {
        case .pl: return base
        case .en: return Translations.en[base] ?? base
        }
    }
}

/// Look up a UI string. The argument is the Polish base text (the default); when the
/// active language is English it is mapped through `Translations.en`, falling back to
/// the Polish text if a translation is missing.
public func tr(_ base: String) -> String {
    LocalizedStrings.translate(base)
}

/// Format variant — the base string carries `printf` placeholders (`%@`, `%d`).
public func trf(_ base: String, _ args: CVarArg...) -> String {
    String(format: tr(base), arguments: args)
}

/// Plural-aware variant of `trf`. `base` is the Polish base string (same key style as
/// `tr`); `count` picks the grammatically-correct one/few/many form for the active
/// language — Polish rules: 1 · 2–4 except 12–14 · the rest — and is inserted for the
/// `%@` placeholder. A base without registered plural forms degrades to `trf(base, count)`.
public func trp(_ base: String, _ count: Int) -> String {
    pluralize(base, count: count, language: LocalizedStrings.current)
        ?? trf(base, "\(count)")
}

/// Observable language selection, persisted across launches. With nothing persisted the
/// system locale decides — see `defaultLanguage(preferredLanguages:)`.
@MainActor
public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()

    private static let defaultsKey = "wega.language"

    @Published public var language: AppLanguage {
        didSet {
            LocalizedStrings.current = language
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:))
        let initial = stored ?? defaultLanguage(preferredLanguages: Locale.preferredLanguages)
        self.language = initial
        LocalizedStrings.current = initial
    }
}
