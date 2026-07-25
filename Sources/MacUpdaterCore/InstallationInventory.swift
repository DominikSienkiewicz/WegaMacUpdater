import Foundation

/// REL-16 — a cask uninstall whose blast radius the user cannot infer from the row
/// they ticked: the application is installed in more than one place, and
/// `brew uninstall <token>` removes the copy Homebrew owns, whichever that is.
public struct AmbiguousBrewUninstall: Identifiable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let appName: String
    public let caskToken: String
    /// Every folder this bundle identifier occupies, sorted. Homebrew's own copy is
    /// one of them; which one cannot be told without asking `brew info`, so the
    /// warning names the candidates instead of promising a path.
    public let locations: [String]

    public var id: String { "\(bundleIdentifier)\u{1}\(caskToken)" }

    public init(bundleIdentifier: String, appName: String, caskToken: String, locations: [String]) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.caskToken = caskToken
        self.locations = locations
    }
}

/// Pure, view-independent handling of the installed-app list that Inventory,
/// Uninstall and Migration all build the same way: scan every directory in
/// `AppScanDirectories`, then collapse whatever the directories reported twice.
///
/// Lifted out of the three views so the collapse rule — the thing that decides
/// which copy a destructive operation is allowed to reach — is unit-tested
/// without SwiftUI.
public enum InstallationInventory {
    /// Collapses entries that describe the same installation, keeping first-seen order.
    ///
    /// REL-16: the key is the `InstallationIdentity`, so overlapping scan
    /// directories reporting one bundle twice still collapse, while two copies of
    /// the same application in two locations stay two rows. De-duplicating by
    /// bundle identifier hid the second copy, and a destructive operation then
    /// acted on whichever copy happened to be scanned first.
    public static func deduplicated(_ apps: [ApplicationInfo]) -> [ApplicationInfo] {
        var seen = Set<String>()
        var result: [ApplicationInfo] = []
        for app in apps {
            if seen.insert(app.id).inserted { result.append(app) }
        }
        return result
    }

    /// The installations the user ticked, in list order. The gate a destructive
    /// operation goes through: it may only reach installations whose identity the
    /// user actually selected.
    public static func selected(
        _ apps: [ApplicationInfo],
        identities: Set<String>
    ) -> [ApplicationInfo] {
        apps.filter { identities.contains($0.id) }
    }

    /// Installations that share a bundle identifier, in list order.
    ///
    /// REL-16: this is the *only* job left for the bundle identifier — grouping
    /// copies of one application, never standing in for their identity.
    public static func groupedByBundleIdentifier(
        _ apps: [ApplicationInfo]
    ) -> [String: [ApplicationInfo]] {
        var groups: [String: [ApplicationInfo]] = [:]
        for app in apps {
            guard let bundleId = app.bundleIdentifier else { continue }
            groups[bundleId, default: []].append(app)
        }
        return groups
    }

    /// The selected cask uninstalls whose target the user cannot infer from the row.
    ///
    /// REL-16 made the second copy of an application visible, which also made it
    /// selectable — and `brew uninstall <token>` acts on the copy Homebrew owns,
    /// not on the path the row shows. `CaskMatcher` classifies by application
    /// *name*, so every copy of Firefox carries the same token and the mismatch is
    /// invisible in the row itself. One entry per cask, even when the user ticked
    /// several copies: it is one command with one blast radius.
    ///
    /// Apps that go to the Trash are absent by construction — those are removed by
    /// path, so they always hit the ticked copy.
    public static func ambiguousBrewUninstalls(
        selected: [ApplicationInfo],
        among apps: [ApplicationInfo]
    ) -> [AmbiguousBrewUninstall] {
        let groups = groupedByBundleIdentifier(apps)
        var warnings: [AmbiguousBrewUninstall] = []
        var reported = Set<String>()
        for app in selected {
            guard app.isManagedByBrew,
                  let token = app.caskToken,
                  let bundleId = app.bundleIdentifier,
                  let copies = groups[bundleId], copies.count > 1
            else { continue }
            let warning = AmbiguousBrewUninstall(
                bundleIdentifier: bundleId,
                appName: app.name,
                caskToken: token,
                locations: copies.map(\.locationLabel).sorted()
            )
            if reported.insert(warning.id).inserted { warnings.append(warning) }
        }
        return warnings
    }

    /// Bundle identifiers installed more than once. The UI shows the location for
    /// these rows, so the user can tell the copies apart before acting on one.
    public static func ambiguousBundleIdentifiers(_ apps: [ApplicationInfo]) -> Set<String> {
        Set(groupedByBundleIdentifier(apps).filter { $0.value.count > 1 }.keys)
    }
}
