import Foundation

/// How much a shown result should apologise for its age (M2).
///
/// Wega now paints the last scan the moment the window opens, instead of an empty hero and
/// a two-minute wait. That is only honest if an old list says it is old — otherwise instant
/// value becomes instant lying. `stale` is the case that must carry a visible date.
public enum ScanFreshness: Equatable, Sendable {
    /// Minutes old. Show it plainly; no caveat needed.
    case fresh
    /// Hours old. Worth stamping with a time.
    case recent
    /// A day or more. Must carry an explicit date and an obvious way to refresh.
    case stale

    private static let freshLimit: TimeInterval = 15 * 60
    private static let recentLimit: TimeInterval = 24 * 60 * 60

    /// `now` is injected so the buckets are testable without reading the clock. A snapshot
    /// stamped in the future (clock skew, restored backup) counts as fresh rather than
    /// wrapping around into "ancient".
    public static func of(scannedAt: Date, now: Date) -> ScanFreshness {
        let age = now.timeIntervalSince(scannedAt)
        if age < freshLimit { return .fresh }
        if age < recentLimit { return .recent }
        return .stale
    }

    /// Fresh results speak for themselves; everything older has to show its date.
    public var needsExplicitTimestamp: Bool {
        self != .fresh
    }
}
