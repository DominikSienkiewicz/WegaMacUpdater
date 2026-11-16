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
    /// The outcome of a removal: which planned items reached the Trash and which failed.
    public struct Result: Equatable, Sendable {
        public var removed: [URL]
        public var failed: [URL]

        public init(removed: [URL] = [], failed: [URL] = []) {
            self.removed = removed
            self.failed = failed
        }
    }

    /// Moves the given items to the Trash (never a permanent delete — SEC-01), reporting
    /// which succeeded and which failed instead of swallowing per-item errors. `trash` is
    /// injected so tests can drive it without touching the user's real Trash.
    @discardableResult
    public static func removeToTrash(
        _ items: [URL],
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Result {
        var result = Result()
        for item in items {
            do {
                try trash(item)
                result.removed.append(item)
            } catch {
                result.failed.append(item)
            }
        }
        return result
    }
}
