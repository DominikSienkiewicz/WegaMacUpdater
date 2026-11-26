import Foundation

/// The column the inventory table is sorted by.
public enum InventorySortKey: String, CaseIterable, Sendable {
    case name, version, bundleId, source, updateDate, diskUsage, diskGrowth

    public var measuresDisk: Bool { self == .diskUsage || self == .diskGrowth }
    public var initiallyAscending: Bool { !measuresDisk }
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
        ascending: Bool,
        footprints: [InstallationIdentity: InventoryFootprint] = [:],
        changes: [InstallationIdentity: InventoryFootprintChange] = [:]
    ) -> (ApplicationInfo, ApplicationInfo) -> Bool {
        let before: (ApplicationInfo, ApplicationInfo) -> Bool
        switch key {
        case .name:       before = { $0.name < $1.name }
        case .version:    before = { ($0.version ?? "") < ($1.version ?? "") }
        case .bundleId:   before = { ($0.bundleIdentifier ?? "") < ($1.bundleIdentifier ?? "") }
        case .source:     before = { sourceRank($0) < sourceRank($1) }
        case .updateDate: before = { ($0.updateDate ?? .distantPast) < ($1.updateDate ?? .distantPast) }
        case .diskUsage, .diskGrowth:
            func bytes(_ keyPath: InstallationIdentity) -> Int64? {
                key == .diskGrowth ? changes[keyPath]?.totalBytes : footprints[keyPath]?.totalBytes
            }
            return { a, b in
                let left = bytes(a.installation)
                let right = bytes(b.installation)
                switch (left, right) {
                case let (left?, right?) where left != right: return ascending ? left < right : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.installation < b.installation
                }
            }
        }
        return { a, b in
            let lhs = ascending ? a : b
            let rhs = ascending ? b : a
            if before(lhs, rhs) { return true }
            if before(rhs, lhs) { return false }
            return a.installation < b.installation
        }
    }

    public static func sorted(
        _ apps: [ApplicationInfo],
        by key: InventorySortKey,
        ascending: Bool,
        footprints: [InstallationIdentity: InventoryFootprint] = [:],
        changes: [InstallationIdentity: InventoryFootprintChange] = [:]
    ) -> [ApplicationInfo] {
        apps.sorted(by: comparator(key: key, ascending: ascending, footprints: footprints, changes: changes))
    }

    private static func sourceRank(_ app: ApplicationInfo) -> Int {
        if app.isManagedByBrew { return 0 }
        return app.isManagedByMas ? 1 : 2
    }
}
