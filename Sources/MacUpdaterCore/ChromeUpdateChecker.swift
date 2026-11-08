import Foundation

/// Parses the releases Chrome's public Version History API is serving now
/// (`.../v1/chrome/platforms/mac/channels/{channel}/versions/all/releases?filter=endtime=none`)
/// → `{"releases":[{"version":"…","fraction":0.25,"fractionGroup":"…"}]}`.
public enum ChromeUpdateParser {
    private struct Response: Decodable {
        struct Release: Decodable {
            let version: String
            let fraction: Double?
        }
        let releases: [Release]
    }

    /// The oldest version served to anyone on the channel, so every Chrome on it is offered at
    /// least this one. A new version reaches Chrome in stages — fractions of separate rollout
    /// groups — and Chrome's own updater keeps a client outside the stage current; the newest
    /// listed version is therefore not an update Chrome would install. Order-independent; `nil`
    /// when nothing is served or the body is not this format.
    public static func versionServedToEveryone(fromReleasesJSON data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let served = decoded.releases.filter { ($0.fraction ?? 0) > 0 && !$0.version.isEmpty }.map(\.version)
        return served.min(by: { isUpgrade(installed: $0, latest: $1) })
    }
}

/// Detects updates for Google Chrome (stable / beta / dev / canary), which self-updates
/// via Keystone (Omaha) while its `google-chrome*` casks are `auto_updates` and lag
/// (the brew drift filter only hides the stale cask after the fact). Queries the releases
/// Chrome's public Version History API serves per channel.
public struct ChromeUpdateChecker: VendorUpdateChecker {
    public static let channelsByBundleID: [String: String] = [
        "com.google.Chrome":        "stable",
        "com.google.Chrome.beta":   "beta",
        "com.google.Chrome.dev":    "dev",
        "com.google.Chrome.canary": "canary"
    ]
    public static func versionsURL(channel: String) -> URL? {
        AppEndpoints.shared.chromeVersionsURL(channel: channel)
    }

    public let client: HTTPClient
    public init(client: HTTPClient = .shared) { self.client = client }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard let bundleID = app.bundleIdentifier,
              let channel = Self.channelsByBundleID[bundleID],
              let installed = app.version, !installed.isEmpty,
              let url = Self.versionsURL(channel: channel) else { return nil }

        return VendorCheckPlan(request: HTTPRequest(url: url, enableETag: true)) { data in
            guard let latest = ChromeUpdateParser.versionServedToEveryone(fromReleasesJSON: data) else { return .decided(.failed) }
            return .candidate(VendorCandidate(latest: latest, installed: installed, source: .chrome))
        }
    }
}
