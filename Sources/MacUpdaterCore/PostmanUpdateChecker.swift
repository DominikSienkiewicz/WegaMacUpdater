import Foundation

/// Parses Postman's Squirrel.Mac update feed. A `GET` to
/// `https://dl.pstmn.io/update/osx_64/{installedVersion}` answers:
/// - **200** with `{"name":"<latest>", "notes":…, "pub_date":…, "url":…}` when a newer
///   build exists — `name` is the version to offer.
/// - **204 No Content** when the running build is already current.
public enum PostmanUpdateParser {
    private struct SquirrelResponse: Decodable { let name: String }

    /// Returns the `name` (latest version) from a Squirrel 200 body, or nil when the
    /// body is empty/unparseable or carries no version.
    public static func latestVersion(fromSquirrelJSON data: Data) -> String? {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(SquirrelResponse.self, from: data) else { return nil }
        let trimmed = decoded.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Detects updates for Postman, which self-updates via Squirrel.Mac (it ships no
/// Sparkle `SUFeedURL`, so the generic Sparkle path can't see it) while its Homebrew
/// cask `postman` is `auto_updates` and lags the real release channel — so neither
/// `brew outdated` nor the cask-version check surfaces the newer build. Queries
/// Postman's own Squirrel feed and compares the short version, the same approach used
/// for ChatGPT and Parallels.
public struct PostmanUpdateChecker: Sendable {
    /// Bundle identifier of `/Applications/Postman.app`.
    public static let bundleIdentifier = "com.postmanlabs.mac"

    /// Squirrel feed for the installed build. Uses the `osx_64` channel: Postman ships a
    /// universal build there, and it is the channel that carries the live latest — the
    /// `osx_arm64` channel is stale even on Apple Silicon. Redirectable via the
    /// `postmanUpdate` endpoint overlay if Postman ever splits the channels.
    public static func updateURL(forVersion version: String) -> URL? {
        AppEndpoints.shared.postmanUpdateURL(version: version)
    }

    private let client: HTTPClient

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard app.bundleIdentifier == Self.bundleIdentifier,
              let installed = app.version, !installed.isEmpty,
              let url = Self.updateURL(forVersion: installed) else { return .notApplicable }

        guard let response = try? await client.get(url, enableETag: true) else { return .unavailable }
        // 204 = Squirrel's "you're current". Any 2xx with no parseable version is also
        // treated as current rather than an error.
        if response.statusCode == 204 { return .upToDate }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let latest = PostmanUpdateParser.latestVersion(fromSquirrelJSON: response.data) else { return .upToDate }

        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: installed,
            availableVersion: latest,
            source: .postman
        ))
    }
}
