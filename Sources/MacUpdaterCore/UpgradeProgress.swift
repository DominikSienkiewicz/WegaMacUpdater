import Foundation

/// What an upgrade run is doing right now, in the order it happens.
public enum UpgradeStage: Equatable, Sendable {
    /// Snapshots and the publisher watchdog, before brew is called at all.
    case preparing
    /// A download is under way. The token is set only when it can be attributed — brew
    /// named it, or the run plans a single package and there is nothing else it could be.
    case downloading(token: String?)
    case installing(token: String)
    /// The post-upgrade rescan, which decides what the list says afterwards.
    case refreshing
}

/// How far an upgrade run has got, in whole packages.
///
/// `completedUnits` counts work that **finished**, the rule `ScanProgress` already follows:
/// a run where one of seven packages failed ends at 6/7 rather than rounding up to a
/// success it did not achieve. Packages are unweighted — a 1.5 GB cask and a 2 MB formula
/// both count as one, because any other weight would be a number we cannot substantiate.
public struct UpgradeProgress: Equatable, Sendable {
    public let completedUnits: Int
    public let totalUnits: Int
    public let stage: UpgradeStage

    public init(completedUnits: Int, totalUnits: Int, stage: UpgradeStage) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.stage = stage
    }

    public var fractionCompleted: Double {
        guard totalUnits > 0 else { return 0 }
        return Double(completedUnits) / Double(totalUnits)
    }
}
