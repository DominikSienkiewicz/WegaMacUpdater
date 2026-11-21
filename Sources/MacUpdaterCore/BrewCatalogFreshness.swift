import Foundation

/// UXP-14 — when a scan may reuse the Homebrew catalog the last `brew update` left behind.
public enum BrewCatalogFreshness {
    public static let launchThreshold: TimeInterval = 30 * 60

    /// Launch scans keep a catalog younger than the threshold; a missing or future stamp refreshes.
    public static func refreshesAtLaunch(lastRefreshedAt: Date?, now: Date) -> Bool {
        guard let lastRefreshedAt else { return true }
        let age = now.timeIntervalSince(lastRefreshedAt)
        return age < 0 || age >= launchThreshold
    }

    /// Whole minutes, at least 1.
    public static func ageMinutes(refreshedAt: Date, scanStartedAt: Date) -> Int {
        max(1, Int(scanStartedAt.timeIntervalSince(refreshedAt) / 60))
    }
}
