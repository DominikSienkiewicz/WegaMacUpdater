import Foundation

/// UXP-14 — when `brew update` last succeeded, kept across launches. Injected so a test's store
/// neither reads nor writes the user's defaults.
@MainActor
struct BrewCatalogStamp {
    let load: @MainActor () -> Date?
    let save: @MainActor (Date) -> Void

    static let defaultsKey = "wega.homebrew.catalogRefreshedAt"

    static let none = BrewCatalogStamp(load: { nil }, save: { _ in })

    static func defaults(_ defaults: UserDefaults, key: String = defaultsKey) -> BrewCatalogStamp {
        BrewCatalogStamp(
            load: { defaults.object(forKey: key) as? Date },
            save: { defaults.set($0, forKey: key) }
        )
    }
}
