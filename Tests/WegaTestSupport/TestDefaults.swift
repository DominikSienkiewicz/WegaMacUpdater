import Foundation

/// In-memory defaults for unit tests, plus cleanup of legacy file-backed test suites.
/// These fixtures test settings logic and serialization inputs, not cross-process persistence.
public enum TestDefaults {

    /// Shared prefix identifying this helper's suites and legacy preference files.
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
        guard let defaults = EphemeralUserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults rejected the generated suite name \(suiteName)")
        }
        return (defaults, { defaults.clear() })
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
