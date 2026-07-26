import Foundation

/// REL-15 — which of a set of casks own an application that is running right now.
///
/// Detection is **generic**: a cask's resolved app-bundle URL is matched against the bundle
/// URLs of the live applications, so it covers the whole installed catalog rather than a
/// hardcoded list of process names. This is the same shape the background updater already
/// used; the window path used to check only 16 hardcoded tokens through `pgrep`.
///
/// The `overrides` map (`MacUpdaterConstants.restartMap`) is consulted **only** to correct the
/// relaunch identity — the process name to quit and the app name to reopen — for the handful of
/// casks whose running process cannot be named reliably from the app itself. It never decides
/// *whether* a cask counts as running: an off-map cask is detected exactly the same way.
public enum RunningCaskDetector {
    /// - Parameters:
    ///   - tokens: the casks to consider, in the order the caller wants the candidates back.
    ///   - appPaths: each cask's resolved app-bundle URL on disk; a cask with no entry (no app
    ///     artifact, or none installed) cannot own a running app and is skipped.
    ///   - running: the applications currently running, as reported by the workspace.
    ///   - overrides: per-token relaunch identity for casks whose process name is atypical.
    /// - Returns: one `RestartInfo` per running cask, in `tokens` order.
    public static func runningApps(
        tokens: [String],
        appPaths: [String: URL],
        running: [RunningApplicationTarget],
        overrides: [String: RestartInfo] = [:]
    ) -> [RestartInfo] {
        let runningByURL = Dictionary(
            running.compactMap { target -> (URL, RunningApplicationTarget)? in
                target.bundleURL.map { (canonicalURL($0), target) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        return tokens.compactMap { token in
            guard let path = appPaths[token],
                  let target = runningByURL[canonicalURL(path)] else { return nil }
            return overrides[token]
                ?? RestartInfo(processName: target.processName, appName: target.appName)
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
