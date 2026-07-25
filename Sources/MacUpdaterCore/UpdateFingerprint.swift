import CryptoKit
import Foundation

/// The identity of "what is available right now", for deciding whether a background check
/// has anything *new* to announce.
///
/// The watermark used to be the update **count**. A round in which one update was installed
/// and another appeared has the same count as the round before it, so the notification stayed
/// silent about something the user had never seen — and a round in which an update vanished
/// and came back re-announced nothing either. Comparing the set of identifiers instead makes
/// "new" mean new.
public enum UpdateFingerprint {
    /// Hash of the sorted, source-tagged keys of everything currently on offer. Stable
    /// across launches (it is persisted between them), so it cannot use `Hasher`, whose
    /// seed is randomised per process.
    public static func of(items: [OutdatedItem], manual: [ManualOutdatedApp]) -> String {
        let keys = items.map(\.key) + manual.map { manualPrefix + $0.path.path }
        guard !keys.isEmpty else { return "" }
        let joined = keys.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// The fingerprint of a background check's result, with the user's ignore/pin rules
    /// applied — the notification announces what the user can actually see.
    public static func of(result: MenuBarScanResult, policies: [String: UpdatePolicy]) -> String {
        let items = UpdatePlanner.applyPolicies(
            UpdatePlanner.outdatedItems(brew: result.brew, mas: result.mas, npm: result.npm),
            policies: policies
        )
        let manual = UpdatePlanner.applyPolicies(result.manualApps, policies: policies)
        return of(items: items, manual: manual)
    }

    /// Manual updates have no package-manager key; the app's path is their identity, the
    /// same tag `ScanStore` uses to address a manual row.
    private static let manualPrefix = "m:"
}
