import Foundation

/// Parses Discord's Squirrel.Mac update feed. Discord's desktop host self-updates
/// through a Squirrel-compatible server: `GET .../updates/{channel}?platform=osx&version={v}`
/// answers **200** `{"name":"0.0.XXXX", …}` with the version to offer, or **204** when current.
public enum DiscordUpdateParser {
    private struct SquirrelResponse: Decodable { let name: String }
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
public struct DiscordUpdateChecker: Sendable {
    public static let channelsByBundleID: [String: String] = [
        "com.hnc.Discord":       "stable",
        "com.hnc.DiscordPTB":    "ptb",
        "com.hnc.DiscordCanary": "canary"
    ]
    public static func updateURL(channel: String, version: String) -> URL? {
        AppEndpoints.shared.discordUpdateURL(channel: channel, version: version)
    }

    private let client: HTTPClient
    public init(client: HTTPClient = .shared) { self.client = client }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard let bundleID = app.bundleIdentifier,
              let channel = Self.channelsByBundleID[bundleID],
              let installed = app.version, !installed.isEmpty,
              let url = Self.updateURL(channel: channel, version: installed) else { return .notApplicable }

        guard let response = try? await client.get(url, enableETag: true) else { return .unavailable }
        if response.statusCode == 204 { return .upToDate }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let latest = DiscordUpdateParser.latestVersion(fromSquirrelJSON: response.data) else { return .upToDate }
        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name, path: app.path,
            installedVersion: installed, availableVersion: latest, source: .discord))
    }
}
