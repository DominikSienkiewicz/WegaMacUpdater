import Foundation

/// The column the inventory table is sorted by.
public enum InventorySortKey: String, CaseIterable, Sendable {
    case name, version, bundleId, source, updateDate
}

/// Ordering for the inventory table. Lifted out of `InventoryView` so the
/// comparator can be unit-tested without SwiftUI.
public enum InventorySort {
    /// REL-16: descending order reverses the *operands*, it does not negate the
    /// result. `!less(a, b)` is `true` for two elements that compare equal, which
    /// makes the predicate neither irreflexive nor asymmetric — and `sort(by:)`
    /// requires a strict weak ordering, so an equal-heavy column (every app with
    /// no version, say) was undefined behaviour rather than merely odd order.
    ///
    /// Ties then fall back to the installation identity, in the same direction
    /// regardless of `ascending`, which keeps the ordering total: two copies of
    /// one application never swap places between two renders of the same list.
    public static func comparator(
        key: InventorySortKey,
        ascending: Bool
    ) -> (ApplicationInfo, ApplicationInfo) -> Bool {
        { a, b in
            let lhs = ascending ? a : b
            let rhs = ascending ? b : a
            if isOrderedBefore(lhs, rhs, by: key) { return true }
            if isOrderedBefore(rhs, lhs, by: key) { return false }
            return a.installation < b.installation
        }
    }

    public static func sorted(
        _ apps: [ApplicationInfo],
        by key: InventorySortKey,
        ascending: Bool
    ) -> [ApplicationInfo] {
        apps.sorted(by: comparator(key: key, ascending: ascending))
    }

    private static func isOrderedBefore(
        _ a: ApplicationInfo,
        _ b: ApplicationInfo,
        by key: InventorySortKey
    ) -> Bool {
        switch key {
        case .name:       return a.name < b.name
        case .version:    return (a.version ?? "") < (b.version ?? "")
        case .bundleId:   return (a.bundleIdentifier ?? "") < (b.bundleIdentifier ?? "")
        case .source:     return sourceRank(a) < sourceRank(b)
        case .updateDate: return (a.updateDate ?? .distantPast) < (b.updateDate ?? .distantPast)
        }
    }

    private static func sourceRank(_ app: ApplicationInfo) -> Int {
        if app.isManagedByBrew { return 0 }
        return app.isManagedByMas ? 1 : 2
    }
}
