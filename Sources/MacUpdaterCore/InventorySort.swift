import Foundation

/// The column the inventory table is sorted by.
public enum InventorySortKey: String, CaseIterable, Sendable {
    case name, version, bundleId, source, updateDate
}

/// Ordering for the inventory table. Lifted out of `InventoryView` so the
/// comparator can be unit-tested without SwiftUI.
public enum InventorySort {
    public static func comparator(
        key: InventorySortKey,
        ascending: Bool
    ) -> (ApplicationInfo, ApplicationInfo) -> Bool {
        { a, b in
            let cmp: Bool
            switch key {
            case .name:     cmp = a.name < b.name
            case .version:  cmp = (a.version ?? "") < (b.version ?? "")
            case .bundleId: cmp = (a.bundleIdentifier ?? "") < (b.bundleIdentifier ?? "")
            case .source:   cmp = sourceRank(a) < sourceRank(b)
            case .updateDate:
                cmp = (a.updateDate ?? .distantPast) < (b.updateDate ?? .distantPast)
            }
            return ascending ? cmp : !cmp
        }
    }

    public static func sorted(
        _ apps: [ApplicationInfo],
        by key: InventorySortKey,
        ascending: Bool
    ) -> [ApplicationInfo] {
        apps.sorted(by: comparator(key: key, ascending: ascending))
    }

    private static func sourceRank(_ app: ApplicationInfo) -> Int {
        if app.isManagedByBrew { return 0 }
        return app.isManagedByMas ? 1 : 2
    }
}
