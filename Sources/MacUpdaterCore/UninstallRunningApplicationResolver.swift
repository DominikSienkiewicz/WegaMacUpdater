import Foundation

/// Matches running processes to one installed copy of an app. Several copies can be
/// installed side by side, so a process at another path is never treated as this copy.
public enum UninstallRunningApplicationResolver {
    public static func resolve(
        app: ApplicationInfo,
        running: [RunningApplicationTarget]
    ) -> RunningApplicationResolution {
        let expectedURL = canonicalURL(app.path)
        let pathMatches = running.filter { target in
            target.bundleURL.map(canonicalURL) == expectedURL
        }
        let hasPathlessMatch = app.bundleIdentifier.map { bundleIdentifier in
            running.contains { $0.bundleURL == nil && $0.bundleIdentifier == bundleIdentifier }
        } ?? false

        // A pathless process with this bundle identifier may be this copy, so even an exact
        // path match is not enough to name the one process to quit.
        if pathMatches.count > 1 || hasPathlessMatch {
            return .ambiguousBundleIdentifier(app.bundleIdentifier ?? app.id)
        }
        return pathMatches.first.map(RunningApplicationResolution.running) ?? .notRunning
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
