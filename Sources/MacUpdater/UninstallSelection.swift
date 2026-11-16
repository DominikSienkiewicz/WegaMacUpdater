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

    static func targets(
        filtered: [ApplicationInfo],
        selected: Set<String>,
        protections: [String: UninstallProtection]
    ) -> [ApplicationInfo] {
        InstallationInventory.selected(selectable(filtered, protections: protections), identities: selected)
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
