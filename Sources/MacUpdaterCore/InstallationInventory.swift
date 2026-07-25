import Foundation

/// Pure, view-independent handling of the installed-app list that Inventory,
/// Uninstall and Migration all build the same way: scan every directory in
/// `AppScanDirectories`, then collapse whatever the directories reported twice.
///
/// Lifted out of the three views so the collapse rule — the thing that decides
/// which copy a destructive operation is allowed to reach — is unit-tested
/// without SwiftUI.
public enum InstallationInventory {
    /// Collapses entries that describe the same installation.
    public static func deduplicated(_ apps: [ApplicationInfo]) -> [ApplicationInfo] {
        var seen = Set<String>()
        var result: [ApplicationInfo] = []
        for app in apps {
            let key = app.bundleIdentifier ?? app.path.path
            if seen.insert(key).inserted { result.append(app) }
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
}
