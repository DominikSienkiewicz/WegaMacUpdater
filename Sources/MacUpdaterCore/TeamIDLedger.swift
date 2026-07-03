import Foundation

/// Result of recording an app's signing Team ID against its history (**FEAT-04 / I-1**).
public enum TeamIDAudit: Equatable, Sendable {
    /// No prior record — we just learned this app's publisher.
    case firstSeen(teamID: String?)
    /// Same publisher as last time.
    case unchanged(teamID: String?)
    /// 🚩 Publisher changed — possible project/cask takeover. Surface loudly.
    case changed(old: String, new: String?)
}

/// Persistent ledger of "which Team ID last signed this bundle id" — the
/// supply-chain watchdog (**FEAT-04 / I-1**). After an upgrade or migration the
/// caller records the freshly-installed app's Team ID; a `.changed` result means
/// the publisher silently changed (a strong tampering / takeover signal that no
/// competitor surfaces).
///
/// Team IDs are public, non-sensitive identifiers, so `UserDefaults` (JSON dict)
/// is appropriate — no Keychain needed. Also seeds cask→publisher data that
/// FEAT-02's confidence scorer can consume over time.
public final class TeamIDLedger: @unchecked Sendable {
    public static let shared = TeamIDLedger()

    private let defaultsKey = "wega.teamIDLedger.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Pure decision — classify a new Team ID against the stored one. Unit-tested.
    public static func classify(stored: String?, new: String?) -> TeamIDAudit {
        guard let stored else { return .firstSeen(teamID: new) }
        return stored == new ? .unchanged(teamID: new) : .changed(old: stored, new: new)
    }

    /// Cask-aware classification (**I-4**). The cask watchdog keys publisher history under
    /// `"cask:<token>"` (see `postCaskUpgrade`), while the inspector looks apps up by their
    /// REAL bundle identifier — two namespaces that never intersect, so a tracked cask read
    /// as `.firstSeen`. This reconciles both baselines on read: prefer the real-bundle-id
    /// history (e.g. one a migration seeded under the real id), and fall back to the cask-key
    /// history only when there is none — so existing watchdog history correlates with no
    /// data migration.
    public static func classifyCask(storedByBundleID: String?, storedByCaskKey: String?, new: String?) -> TeamIDAudit {
        classify(stored: storedByBundleID ?? storedByCaskKey, new: new)
    }

    /// `classifyCask`, but withholds a verdict (`nil`) when NOTHING about the publisher was
    /// measured — no fresh Team ID and no history under either key. Lets the inspector hide the
    /// Team ID rows for a cask whose signature couldn't be read and that has no baseline, rather
    /// than render a hollow "—" / first-sighting placeholder (honesty: show a signal only when
    /// something was actually measured).
    public static func classifyCaskOrNil(storedByBundleID: String?, storedByCaskKey: String?, new: String?) -> TeamIDAudit? {
        guard new != nil || storedByBundleID != nil || storedByCaskKey != nil else { return nil }
        return classifyCask(storedByBundleID: storedByBundleID, storedByCaskKey: storedByCaskKey, new: new)
    }

    /// Records `teamID` for `bundleID`, returning the audit vs. the previous value.
    /// Only concrete (non-nil) IDs are persisted, so an unreadable signature never
    /// erases a known-good baseline.
    @discardableResult
    public func record(bundleID: String, teamID: String?) -> TeamIDAudit {
        lock.lock(); defer { lock.unlock() }
        var map = (defaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        let audit = Self.classify(stored: map[bundleID], new: teamID)
        if let teamID, !teamID.isEmpty { map[bundleID] = teamID }
        defaults.set(map, forKey: defaultsKey)
        return audit
    }

    /// Last known Team ID for a bundle id (feeds FEAT-02 corroboration).
    public func teamID(forBundleID bundleID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (defaults.dictionary(forKey: defaultsKey) as? [String: String])?[bundleID]
    }
}
