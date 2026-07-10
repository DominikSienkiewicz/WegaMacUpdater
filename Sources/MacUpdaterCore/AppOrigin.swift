import Foundation

/// Where an installed app came from — its package-manager provenance, independent of
/// how an update for it happens to be delivered.
///
/// This is the **single source of truth** both windows use to label an app's origin:
/// the Inventory ("Spis aplikacji") "ŹRÓDŁO" badge and the Updates ("Aktualizacje")
/// section grouping both derive from ``of(_:)``. Keeping one classifier is what stops
/// the two windows from disagreeing — e.g. Docker showing "Brew" in the inventory but
/// "Ręcznie zainstalowane" in the updates list. A regression there fails
/// `AppOriginTests` / the consistency test rather than only surfacing as a visual bug.
public enum AppOrigin: Codable, Equatable, Sendable {
    case brew
    case appStore
    case npm
    case manual

    /// Classifies an installed `.app`. Mirrors the precedence the Inventory badge has
    /// always used: a Mac App Store receipt wins over a Homebrew cask match (the
    /// scanner already clears `isManagedByBrew` when a `_MASReceipt` is present, but we
    /// keep the precedence explicit so the rule lives in one place).
    public static func of(_ app: ApplicationInfo) -> AppOrigin {
        if app.isManagedByMas { return .appStore }
        if app.isManagedByBrew { return .brew }
        return .manual
    }
}
