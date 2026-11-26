import Foundation

/// UX-13: the "app + leftovers" cleanup for an uninstalled application, made to work
/// regardless of where the app was installed from.
///
/// What counts as a leftover is decided by ``LeftoverPlanner``; this type only removes the
/// items the user consented to.
///
/// SEC-01: items are only ever **moved to the Trash**, never deleted with `removeItem`.
/// Removal takes the Trash as an injected closure so it can be unit-tested without the
/// user's real Trash.
public enum LeftoverCleanup {
    /// The outcome of a removal: which planned items reached the Trash (or were already gone) and
    /// which failed.
    public struct Result: Equatable, Sendable {
        public var removed: [URL]
        public var failed: [URL]
        /// A subset of `removed` whose original location was empty before the move.
        public fileprivate(set) var alreadyAbsent: [URL] = []
        public fileprivate(set) var failureReasons: [URL: String] = [:]

        public init(removed: [URL] = [], failed: [URL] = []) {
            self.removed = removed
            self.failed = failed
        }
    }

    /// Moves the given items to the Trash (never a permanent delete — SEC-01), reporting
    /// which succeeded and which failed instead of swallowing per-item errors. An item `lstat`
    /// finds missing at its turn counts as removed: a folder trashed earlier in the list took it
    /// along, or `brew --zap` removed it for another app of the run. `trash` and `lstat` are
    /// injected so tests can drive them without touching the user's real Trash.
    @discardableResult
    public static func removeToTrash(
        _ items: [URL],
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        lstat: (URL) throws -> CleanupEntry? = { try LiveCleanupFileSystem().entry(at: $0) }
    ) -> Result {
        var result = Result()
        for item in items {
            if isGone(item, lstat: lstat) {
                result.alreadyAbsent.append(item)
                result.removed.append(item)
                continue
            }
            do {
                try trash(item)
                result.removed.append(item)
            } catch {
                result.failed.append(item)
                result.failureReasons[item] = error.localizedDescription
            }
        }
        return result
    }

    /// Only a successful `lstat` that finds nothing; an item that cannot be checked is not gone.
    private static func isGone(_ item: URL, lstat: (URL) throws -> CleanupEntry?) -> Bool {
        do {
            return try lstat(item) == nil
        } catch {
            return false
        }
    }
}
