import Foundation

/// Why an auto-rollback happened, kept alongside the durable mark so a log line or a future
/// surface can tell a failed canary apart from a caught publisher swap (REL-07).
public enum CaskRollbackReason: String, Codable, Equatable, Sendable {
    /// A Gatekeeper / bundle-identity check rejected the new build and the previous one was
    /// restored.
    case checkFailed
    /// The publisher's Team ID changed between versions and the previous, trusted build was
    /// restored.
    case publisherChanged
}

/// Persistent record of which casks an auto-rollback reverted and are now waiting for a retry
/// (REL-07).
///
/// After `CaskRollbackGuard.verify` restores the previous bundle, Homebrew's Caskroom still
/// records the *new* version — so `brew outdated` reports nothing, and `ManualUpdateScanner`,
/// which defers to brew for brew-managed apps, drops the app from every scan. The reverted
/// version would then be invisible until upstream ships something newer.
///
/// This ledger is the memory that survives that silence. A token is marked when the guard
/// rolls it back, and cleared the moment a genuinely healthy install lands — the `.healthy`
/// verdict reached by the user's conscious "Aktualizuj przez Brew" retry, which
/// force-reinstalls the cask and thereby repairs the Caskroom metadata in the same pass. While
/// a token is marked, `ManualUpdateScanner` forces it back onto the update list with the
/// "cofnięto — ponów próbę" label so the reverted app can never read as current.
///
/// Cask tokens are public, non-sensitive identifiers, so `UserDefaults` (a JSON dict) is the
/// right store — the same choice `TeamIDLedger` makes for the publisher watchdog.
public final class CaskRollbackLedger: @unchecked Sendable {
    public static let shared = CaskRollbackLedger()

    private let defaultsKey = "wega.caskRollbackLedger.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The ledger action a verify verdict implies. Only the two verdicts that leave the
    /// *previous* build on disk (a successful restore) arm the mark; `.healthy` disarms it, and
    /// everything else — including `.rollbackFailed`, a louder failure surfaced elsewhere as a
    /// critical result — leaves the ledger untouched.
    public static func rollbackReason(for verdict: CaskValidationVerdict) -> CaskRollbackReason? {
        switch verdict {
        case .rolledBack:                                  return .checkFailed
        case .publisherChangedAndRolledBack:               return .publisherChanged
        case .healthy, .rollbackFailed, .publisherChanged: return nil
        }
    }

    /// Folds one verify verdict into the ledger: a rolled-back verdict records the mark, a
    /// healthy one clears it, anything else is left as-is. This is the single call both public
    /// `CaskRollbackGuard.verify` overloads make, so foreground, background and the conscious
    /// retry all keep one rolled-back memory.
    public func apply(token: String, verdict: CaskValidationVerdict) {
        if let reason = Self.rollbackReason(for: verdict) {
            recordRollback(token: token, reason: reason)
        } else if verdict == .healthy {
            clear(token: token)
        }
    }

    public func recordRollback(token: String, reason: CaskRollbackReason) {
        lock.lock(); defer { lock.unlock() }
        var map = stored()
        map[token] = reason.rawValue
        defaults.set(map, forKey: defaultsKey)
    }

    public func clear(token: String) {
        lock.lock(); defer { lock.unlock() }
        var map = stored()
        guard map.removeValue(forKey: token) != nil else { return }
        defaults.set(map, forKey: defaultsKey)
    }

    public func isRolledBack(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stored()[token] != nil
    }

    public func rolledBackTokens() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(stored().keys)
    }

    public func reason(forToken token: String) -> CaskRollbackReason? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = stored()[token] else { return nil }
        return CaskRollbackReason(rawValue: raw)
    }

    /// Reads the backing dict. Callers hold `lock`; this never locks, so it can be reused from
    /// the mutating methods without a re-entrant (non-recursive) `NSLock` deadlock.
    private func stored() -> [String: String] {
        (defaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }
}
