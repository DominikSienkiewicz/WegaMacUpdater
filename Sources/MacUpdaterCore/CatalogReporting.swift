import Foundation

/// UX-14 — decides which scanned apps Wega has **no known way to update**, and turns one such app
/// into a ``CatalogIssueBuilder`` so the user can report it to the community catalog.
///
/// ``AppOrigin/of(_:)`` classifies *provenance* — `.manual` merely means "installed by hand", not
/// "unupdatable". A hand-installed app can still be tracked by the ``AppCatalog`` (GitHub /
/// JetBrains / Synology / a Sparkle-feed override) or managed by Homebrew / the Mac App Store, in
/// which case it already has an update source and must not be offered for reporting. Eligibility is
/// therefore a strictly finer condition than the Inventory "Ręcznie" badge.
public enum CatalogReporting {
    /// True when Wega already knows how to deliver updates for `app`: it is managed by Homebrew or
    /// the Mac App Store, or its bundle identifier appears in one of the catalog's lookup tables.
    ///
    /// This deliberately does not read the app's own `Info.plist` `SUFeedURL`: that is per-app disk
    /// I/O, whereas catalog membership + brew/MAS is a pure function of already-scanned state and is
    /// exactly the "known source" the community-catalog loop cares about.
    public static func hasKnownUpdateSource(_ app: ApplicationInfo, catalog: AppCatalog) -> Bool {
        if app.isManagedByBrew || app.isManagedByMas { return true }
        guard let bundleID = app.bundleIdentifier else { return false }
        return catalog.github.contains { $0.bundleId == bundleID }
            || catalog.jetbrains.contains { $0.bundleId == bundleID }
            || catalog.synology.contains { $0.bundleId == bundleID }
            || catalog.sparkleFeedOverrides.contains { $0.bundleId == bundleID }
    }

    /// A prefilled-issue builder for `app`, mapping the fields the catalog maintainers need from an
    /// already-scanned ``ApplicationInfo``. `feedURL` is left `nil` — it is not stored on the model —
    /// while the observed `version` is carried as the ``CatalogIssueBuilder/versionFormat`` example.
    public static func issueBuilder(for app: ApplicationInfo) -> CatalogIssueBuilder {
        CatalogIssueBuilder(
            appName: app.name,
            bundleID: app.bundleIdentifier ?? "",
            feedURL: nil,
            versionFormat: app.version
        )
    }
}
