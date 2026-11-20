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
        var current: AppLanguage
        init(_ language: AppLanguage) { current = language }
    }
    private static let storage = Storage(.pl)

    /// Bound only inside `withScopedLanguage`; the app never binds it, so it always uses `storage`.
    @TaskLocal private static var scopedStorage: Storage?

    private static var activeStorage: Storage { scopedStorage ?? storage }

    static var current: AppLanguage {
        get { let active = activeStorage; return active.lock.withLock { active.current } }
        set { let active = activeStorage; active.lock.withLock { active.current = newValue } }
    }

    /// Runs `body` with `language` active for the calling task and the child tasks it creates.
    /// Reads and writes of `current` inside go to a private store, so a test that forces a
    /// language cannot switch it under tests running in parallel in the same process.
    static func withScopedLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        try $scopedStorage.withValue(Storage(language), operation: body)
    }

    /// The `async` form of `withScopedLanguage(_:_:)`.
    static func withScopedLanguage<T>(
        _ language: AppLanguage,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $scopedStorage.withValue(Storage(language), operation: body, isolation: isolation)
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

    private let defaults: UserDefaults

    @Published public var language: AppLanguage {
        didSet {
            LocalizedStrings.current = language
            defaults.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    /// `defaults` is injectable so tests can drive a throwaway suite instead of the
    /// process-wide `.standard` domain (QA-01 — unblocking store testability).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:))
        let initial = stored ?? defaultLanguage(preferredLanguages: Locale.preferredLanguages)
        self.language = initial
        LocalizedStrings.current = initial
    }
}
