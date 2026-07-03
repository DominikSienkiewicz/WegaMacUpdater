import Foundation

/// Parses Chrome's public Version History API
/// (`.../v1/chrome/platforms/mac/channels/{channel}/versions`) → `{"versions":[{"version":"…"}]}`.
/// The feed order isn't contractually newest-first, so we pick the max by version compare.
public enum ChromeUpdateParser {
    private struct Response: Decodable {
        struct Version: Decodable { let version: String }
        let versions: [Version]
    }
    public static func newestVersion(fromVersionHistoryJSON data: Data) -> String? {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let versions = decoded.versions.map(\.version).filter { !$0.isEmpty }
        return versions.max(by: { isUpgrade(installed: $0, latest: $1) })
    }
}

/// Detects updates for Google Chrome (stable / beta / dev / canary), which self-updates
/// via Keystone (Omaha) while its `google-chrome*` casks are `auto_updates` and lag
/// (the brew drift filter only hides the stale cask after the fact). Queries Chrome's
/// public Version History API per channel.
public struct ChromeUpdateChecker: Sendable {
    public static let channelsByBundleID: [String: String] = [
        "com.google.Chrome":        "stable",
        "com.google.Chrome.beta":   "beta",
        "com.google.Chrome.dev":    "dev",
        "com.google.Chrome.canary": "canary"
    ]
    public static func versionsURL(channel: String) -> URL? {
        AppEndpoints.shared.chromeVersionsURL(channel: channel)
    }

    private let client: HTTPClient
    public init(client: HTTPClient = .shared) { self.client = client }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard let bundleID = app.bundleIdentifier,
              let channel = Self.channelsByBundleID[bundleID],
              let installed = app.version, !installed.isEmpty,
              let url = Self.versionsURL(channel: channel) else { return .notApplicable }

        guard let response = try? await client.get(url, enableETag: true) else { return .unavailable }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let latest = ChromeUpdateParser.newestVersion(fromVersionHistoryJSON: response.data) else { return .failed }
        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name, path: app.path,
            installedVersion: installed, availableVersion: latest, source: .chrome))
    }
}
