import CoreServices
import Foundation
import MacUpdaterCore

struct InventoryAppActivity: Equatable, Sendable {
    let lastOpenedAt: Date?
    let protection: UninstallProtection?

    func isLargeAndUnused(bytes: Int64?, now: Date) -> Bool {
        guard let bytes, bytes > 1_000_000_000, let lastOpenedAt else { return false }
        return now.timeIntervalSince(lastOpenedAt) >= 90 * 24 * 60 * 60
    }

    func uninstallReviewTarget(for app: ApplicationInfo) -> URL? {
        protection == nil ? app.path : nil
    }

    static func read(
        apps: [ApplicationInfo],
        protections: [String: UninstallProtection],
        lastOpened: (URL) -> Date? = spotlightLastOpened
    ) -> [InstallationIdentity: Self] {
        var result: [InstallationIdentity: Self] = [:]
        for app in apps {
            if Task.isCancelled { break }
            result[app.installation] = Self(lastOpenedAt: lastOpened(app.path), protection: protections[app.id])
        }
        return result
    }

    private static func spotlightLastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
