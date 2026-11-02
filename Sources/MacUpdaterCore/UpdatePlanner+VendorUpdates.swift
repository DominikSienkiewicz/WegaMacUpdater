import Foundation

public extension UpdatePlanner {
    /// Uses verified cask ownership and comparable versions to show one offer per installation.
    /// Raw source results stay intact; the selected row keeps its original version and action.
    /// Shared-package updates and incomparable versions remain separate offers.
    static func reconciledUpdates(
        items: [OutdatedItem], manual: [ManualOutdatedApp]
    ) -> (items: [OutdatedItem], manual: [ManualOutdatedApp]) {
        let casks = Dictionary(items.filter { $0.kind == .cask }.map { ($0.name, $0) },
                               uniquingKeysWith: { first, _ in first })
        var replacedCasks = Set<String>()
        var replacedManual = Set<Int>()
        for (index, vendor) in manual.enumerated() {
            guard vendor.origin == .brew, let token = vendor.caskPolicyToken, let cask = casks[token] else { continue }
            switch vendorVersionOrder(vendor, caskVersion: cask.to) {
            case .orderedSame, .orderedDescending: replacedCasks.insert(cask.key)
            case .orderedAscending: replacedManual.insert(index)
            case .unknown: break
            }
        }
        return (
            items.filter { !replacedCasks.contains($0.key) },
            manual.enumerated().filter { !replacedManual.contains($0.offset) }.map(\.element)
        )
    }
}

extension UpdatePlanner {
    static func vendorVersionOrder(_ vendor: ManualOutdatedApp, caskVersion: String?) -> VersionOrder {
        switch vendor.source {
        case .cask, .mas, .obsidian: return .unknown
        default: break
        }
        guard vendor.completionRequirement?.field != .sharedPackage,
              let vendorVersion = vendor.availableVersion, let caskVersion else { return .unknown }
        // The shared tolerant parser can ignore opaque components. Only complete numeric
        // release/build encodings justify hiding another source's offer.
        let numericVersion = #"^\d+(?:\.\d+)*(?:[,+]\d+(?:\.\d+)*|-\d+| \(\d+\))?$"#
        guard vendorVersion.range(of: numericVersion, options: .regularExpression) != nil,
              caskVersion.range(of: numericVersion, options: .regularExpression) != nil else { return .unknown }
        let order = compareVersions(vendorVersion, caskVersion, scheme: .buildNumbered)
        if order == .orderedSame, hasExplicitBuild(vendorVersion) != hasExplicitBuild(caskVersion) { return .unknown }
        return order
    }

    private static func hasExplicitBuild(_ version: String) -> Bool {
        version.contains(where: { ",+- (".contains($0) }) || version.split(separator: ".").count > 3
    }

    static func preferredUpdate(_ candidate: ManualOutdatedApp, over existing: ManualOutdatedApp) -> Bool {
        let order: VersionOrder
        if case .cask = candidate.source {
            if candidate.rolledBack { return true }
            order = vendorVersionOrder(existing, caskVersion: candidate.availableVersion)
            if order == .orderedAscending { return true }
            if order == .orderedDescending { return false }
        } else if case .cask = existing.source {
            if existing.rolledBack { return false }
            order = vendorVersionOrder(candidate, caskVersion: existing.availableVersion)
            if order == .orderedDescending { return true }
            if order == .orderedAscending { return false }
        }
        return candidate.source.priority > existing.source.priority
    }
}
