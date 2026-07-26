import Foundation

/// UX-13: the "app + leftovers" cleanup for an uninstalled application, made to work
/// regardless of where the app was installed from.
///
/// The `~/Library` paths come from ``MigrationPlanner/libraryLeftoverCandidates(bundleId:home:)``
/// — the same per-bundle-id builder (with SEC-06 sanitisation) the app already trusts —
/// so there is a single source of truth for what "leftovers" means, whether the app was
/// managed by Homebrew or dropped into `/Applications` by hand.
///
/// SEC-01: items are only ever **moved to the Trash**, never deleted with `removeItem`,
/// and nothing is planned for an unsafe bundle id. Planning is pure and separated from
/// removal so the two can be unit-tested without a real home directory or a real Trash.
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

    /// The `~/Library` items an app left behind that still exist on disk, in the
    /// planner's canonical order.
    ///
    /// Reuses ``MigrationPlanner/libraryLeftoverCandidates(bundleId:home:)`` and keeps only
    /// the paths that are actually present, so the checkbox sheet never offers a file that
    /// isn't there. Pure: `fileExists` is injected, so this is exercised against a temp
    /// directory in tests and against the real filesystem in the app.
    public static func plan(
        bundleID: String,
        home: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [URL] {
        MigrationPlanner.libraryLeftoverCandidates(bundleId: bundleID, home: home)
            .filter(fileExists)
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
