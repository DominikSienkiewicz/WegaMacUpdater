import Foundation
import MacUpdaterCore

/// Selection rules for the uninstall list. Protected rows stay visible but are never
/// selectable, so every selection path goes through here.
enum UninstallSelection {
    static func selectable(
        _ apps: [ApplicationInfo],
        protections: [String: UninstallProtection]
    ) -> [ApplicationInfo] {
        UninstallEligibility.removable(apps, protections: protections)
    }

    static func selectAll(
        filtered: [ApplicationInfo],
        protections: [String: UninstallProtection]
    ) -> Set<String> {
        Set(selectable(filtered, protections: protections).map(\.id))
    }

    static func togglingVisible(
        _ apps: [ApplicationInfo], in selected: Set<String>, protections: [String: UninstallProtection]
    ) -> Set<String> {
        let visible = selectAll(filtered: apps, protections: protections)
        return selected.isSuperset(of: visible) ? selected.subtracting(visible) : selected.union(visible)
    }

    static func targets(
        filtered: [ApplicationInfo],
        selected: Set<String>,
        protections: [String: UninstallProtection]
    ) -> [ApplicationInfo] {
        InstallationInventory.selected(selectable(filtered, protections: protections), identities: selected)
    }

    /// The selectable apps installed at `bundle`, the app a Cleanup row handed over. A protected
    /// or missing app starts with nothing selected.
    static func preselection(
        for bundle: URL,
        in apps: [ApplicationInfo],
        protections: [String: UninstallProtection]
    ) -> Set<String> {
        let path = bundle.standardizedFileURL.path
        return Set(selectable(apps, protections: protections).filter { $0.path.standardizedFileURL.path == path }.map(\.id))
    }

    static func duplicateGroup(for bundle: URL, in apps: [ApplicationInfo]) -> String? {
        let identity = InstallationIdentity(path: bundle)
        guard let id = apps.first(where: { $0.installation == identity })?.bundleIdentifier,
              InstallationInventory.ambiguousBundleIdentifiers(apps).contains(id) else { return nil }
        return id
    }

    static func selectAllSymbol(
        filtered: [ApplicationInfo],
        selected: Set<String>,
        protections: [String: UninstallProtection]
    ) -> String {
        let selectableCount = selectable(filtered, protections: protections).count
        let targetCount = targets(filtered: filtered, selected: selected, protections: protections).count
        if targetCount == 0 { return "square" }
        if targetCount == selectableCount { return "checkmark.square.fill" }
        return "minus.square.fill"
    }
}
