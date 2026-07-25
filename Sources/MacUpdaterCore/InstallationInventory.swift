import Foundation

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

    /// Bundle identifiers installed more than once. The UI shows the location for
    /// these rows, so the user can tell the copies apart before acting on one.
    public static func ambiguousBundleIdentifiers(_ apps: [ApplicationInfo]) -> Set<String> {
        Set(groupedByBundleIdentifier(apps).filter { $0.value.count > 1 }.keys)
    }
}
