import Foundation

/// Isolated `UserDefaults` domains for tests, and the sweep that keeps them from piling up.
///
/// A suite created by `UserDefaults(suiteName:)` is file-backed: it leaves
/// `~/Library/Preferences/<suite>.plist` on disk, and `removePersistentDomain(forName:)` empties
/// that file without unlinking it. One suite per test therefore deposited one plist — a full
/// 4 KB block on APFS — per test, per run. A few weeks of local runs left 5235 of them behind,
/// roughly 90% of the files in `~/Library/Preferences`.
///
/// Deleting the file in teardown is not sufficient on its own: `cfprefsd` is a separate daemon
/// that holds the domain in memory and flushes it on its own schedule, which for a short-lived
/// test process lands *after* the process exits. Measured, not assumed — a run that ended with
/// zero leftover files had ten of them again a minute later, each an empty 42-byte plist the
/// daemon had written back. Nothing inside the process can outlast that, so what actually
/// reclaims the disk is `sweepStaleSuites`: every run starts by deleting what earlier runs left.
/// The cost of the race is bounded to one run's worth of files instead of growing forever.
///
/// `ArchitectureReviewRegressionTests` fails the build if a test builds a suite by hand instead.
public enum TestDefaults {

    /// Shared prefix on every suite this helper creates. It is what makes the leftovers of a
    /// crashed run identifiable — both to `sweepStaleSuites` and to a human with a glob.
    public static let suitePrefix = "wega.tests"

    /// How old a leftover plist must be before a run treats it as another run's litter.
    /// Comfortably longer than the window in which `cfprefsd` writes a file back, and far
    /// longer than any file a concurrently running test process could have just created.
    private static let staleAfter: TimeInterval = 600

    /// An empty defaults domain isolated to one test, plus the teardown that erases it.
    /// Callers must `defer { teardown() }` immediately — nothing else runs it.
    ///
    /// - Parameter label: short identifier for the test that owns the suite; it lands in the
    ///   suite name, which is what makes a leftover plist traceable to its source.
    public static func isolated(_ label: String) -> (defaults: UserDefaults, teardown: () -> Void) {
        _ = sweepOnce
        let suiteName = "\(suitePrefix).\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults rejected the generated suite name \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, { destroy(suiteName: suiteName, defaults: defaults) })
    }

    /// Drops the domain from the running process and unlinks the plist. The unlink is
    /// best-effort by nature — see the note on `cfprefsd` above — but it does win whenever the
    /// daemon has already flushed, and it keeps a long run from carrying every suite it opened.
    private static func destroy(suiteName: String, defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeSuite(named: suiteName)
        guard let file = preferencesDirectory()?.appendingPathComponent("\(suiteName).plist") else {
            return
        }
        try? FileManager.default.removeItem(at: file)
    }

    /// Runs on the first isolated suite of the process: `let` statics are lazy and run once.
    private static let sweepOnce: Void = sweepStaleSuites()

    /// Deletes the plists left by runs that have long since exited. The age threshold is what
    /// makes this safe to run while other test processes are working: their files are seconds
    /// old, so a sweep cannot pull a live suite out from under a parallel run.
    private static func sweepStaleSuites() {
        guard let directory = preferencesDirectory() else { return }
        let cutoff = Date().addingTimeInterval(-staleAfter)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in contents ?? [] where isSuitePlist(url) {
            let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isSuitePlist(_ url: URL) -> Bool {
        url.pathExtension == "plist" && url.lastPathComponent.hasPrefix("\(suitePrefix).")
    }

    private static func preferencesDirectory() -> URL? {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Preferences", isDirectory: true)
    }
}
