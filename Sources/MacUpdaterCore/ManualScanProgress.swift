import Foundation

/// UXP-13 — how far the vendor phase of a scan has got, in whole apps. It counts answers that
/// have come back, never time: nothing here estimates how long the rest will take.
public struct ManualScanProgress: Equatable, Sendable {
    /// Apps whose every check has come back.
    public let checkedApps: Int
    /// Apps with at least one check in this scan.
    public let totalApps: Int

    public init(checkedApps: Int, totalApps: Int) {
        self.checkedApps = checkedApps
        self.totalApps = totalApps
    }
}

/// Turns finished checks into finished apps.
///
/// One app has several checkers in flight at once (its cask, Sparkle, the vendor feeds), and
/// they come back in any order, so an app counts as checked only when the last of its checks
/// is back. An app with no checks is not counted at all: there is nothing to wait for.
struct ManualScanProgressTracker {
    private var outstanding: [InstallationIdentity: Int]
    private let totalApps: Int
    private var checkedApps = 0

    init(checksPerApp: [InstallationIdentity: Int]) {
        outstanding = checksPerApp.filter { $0.value > 0 }
        totalApps = outstanding.count
    }

    var progress: ManualScanProgress {
        ManualScanProgress(checkedApps: checkedApps, totalApps: totalApps)
    }

    /// Records one finished check of `app`. Returns `true` when it was that app's last one,
    /// which is the only moment the count changes.
    mutating func finish(_ app: InstallationIdentity) -> Bool {
        guard let left = outstanding[app] else { return false }
        guard left == 1 else {
            outstanding[app] = left - 1
            return false
        }
        outstanding[app] = nil
        checkedApps += 1
        return true
    }
}
