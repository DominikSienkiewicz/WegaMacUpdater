import Foundation
import MacUpdaterCore

/// Ownership captured by the scan. A confirmation keeps its own selection and snapshot.
struct UninstallCopyPlan: Sendable {
    private var reviews: [String: UninstallDuplicateReview] = [:]
    private var uncertain: Set<String> = []
    private var conflicts: Set<String> = []

    init(apps: [ApplicationInfo] = [], scanComplete: Bool = true, brewPrefix: URL? = nil) {
        for (identifier, group) in InstallationInventory.groupedByBundleIdentifier(apps) where group.count > 1 {
            reviews[identifier] = UninstallDuplicateReview(
                bundleIdentifier: identifier, apps: group, scanComplete: scanComplete, brewPrefix: brewPrefix
            )
        }
        let managed = apps.filter(\.isManagedByBrew)
        for group in Dictionary(grouping: managed, by: \.caskToken).values where group.count > 1 {
            let identifiers = Set(group.map(\.bundleIdentifier))
            if identifiers.count != 1 || identifiers.contains(nil) { uncertain.formUnion(group.map(\.id)) }
        }
        if !scanComplete { uncertain.formUnion(managed.map(\.id)) }
    }

    func review(for identifier: String) -> UninstallDuplicateReview? { reviews[identifier] }

    func duplicateGroup(for bundle: URL) -> String? {
        UninstallSelection.duplicateGroup(for: bundle, in: reviews.values.flatMap(\.visibleApps))
    }

    func routed(_ app: ApplicationInfo) -> ApplicationInfo? {
        guard !uncertain.contains(app.id) else { return nil }
        guard let review = app.bundleIdentifier.flatMap({ reviews[$0] }) else { return app }
        return review.target(for: app)
    }

    func selecting(_ targets: [ApplicationInfo]) -> Self {
        var selection = self
        selection.conflicts = Set(InstallationInventory.groupedByBundleIdentifier(targets).values
            .filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        return selection
    }

    func block(for app: ApplicationInfo) -> UninstallBlock? {
        if conflicts.contains(app.id) { return .multipleSelectedCopies }
        if uncertain.contains(app.id) { return .unverifiedCopy }
        guard let review = app.bundleIdentifier.flatMap({ reviews[$0] }) else { return nil }
        return review.stillAllows(app) ? nil : .unverifiedCopy
    }

    func preservesData(for app: ApplicationInfo) -> Bool {
        guard let review = app.bundleIdentifier.flatMap({ reviews[$0] }) else { return false }
        return !review.visibleApps.isEmpty
    }

    func keptPaths(for app: ApplicationInfo) -> [URL] {
        guard !conflicts.contains(app.id), let review = app.bundleIdentifier.flatMap({ reviews[$0] }) else { return [] }
        return review.visibleApps.filter { $0.id != app.id }.map(\.path)
    }
}
