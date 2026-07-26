import Foundation

/// Parses Discord's Squirrel.Mac update feed. Discord's desktop host self-updates
/// through a Squirrel-compatible server: `GET .../updates/{channel}?platform=osx&version={v}`
/// answers **200** `{"name":"0.0.XXXX", …}` with the version to offer, or **204** when current.
public enum DiscordUpdateParser {
    public static func latestVersion(fromSquirrelJSON data: Data) -> String? {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(SquirrelResponse.self, from: data) else { return nil }
        let trimmed = decoded.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Detects updates for Discord (stable / PTB / Canary), which self-updates via
/// Squirrel.Mac (no Sparkle `SUFeedURL`) while its `discord*` casks are `auto_updates`
/// and lag — so neither `brew outdated` nor the cask-version check sees the new build.
/// Same approach as Postman and ChatGPT.
public struct DiscordUpdateChecker: VendorUpdateChecker {
    public static let channelsByBundleID: [String: String] = [
        "com.hnc.Discord":       "stable",
        "com.hnc.DiscordPTB":    "ptb",
        "com.hnc.DiscordCanary": "canary"
    ]
    public static func updateURL(channel: String, version: String) -> URL? {
        AppEndpoints.shared.discordUpdateURL(channel: channel, version: version)
    }

    public let client: HTTPClient
    public init(client: HTTPClient = .shared) { self.client = client }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard let bundleID = app.bundleIdentifier,
              let channel = Self.channelsByBundleID[bundleID],
              let installed = app.version, !installed.isEmpty,
              let url = Self.updateURL(channel: channel, version: installed) else { return nil }

        // 204 = Squirrel's "you're current"; any 2xx with no parseable version is also
        // treated as current rather than an error.
        return VendorCheckPlan(
            request: HTTPRequest(url: url, enableETag: true),
            upToDateStatusCodes: [204]
        ) { data in
            guard let latest = DiscordUpdateParser.latestVersion(fromSquirrelJSON: data) else { return .decided(.upToDate) }
            return .candidate(VendorCandidate(latest: latest, installed: installed, source: .discord))
        }
    }
}
