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
        if pathMatches.count == 1, let match = pathMatches.first {
            return .running(match)
        }
        if pathMatches.count > 1 {
            return .ambiguousBundleIdentifier(app.bundleIdentifier ?? app.id)
        }

        guard let bundleIdentifier = app.bundleIdentifier else { return .notRunning }
        let pathlessMatches = running.filter {
            $0.bundleURL == nil && $0.bundleIdentifier == bundleIdentifier
        }
        return pathlessMatches.isEmpty ? .notRunning : .ambiguousBundleIdentifier(bundleIdentifier)
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
