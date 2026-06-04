import Foundation

/// Parses the Antigravity IDE update API response.
///
/// Antigravity (Google's VS Code-based agentic IDE) is distributed as a
/// Homebrew cask, but the cask is frozen at an old version while the app
/// updates itself through Google's own endpoint. The JSON returned by that
/// endpoint is shaped like the VS Code update API — and its `name` /
/// `productVersion` fields carry the *VS Code base* version, not Antigravity's
/// own. The real product version is only encoded in the download URL path:
/// `…/antigravity/stable/<X.Y.Z>-<build>/darwin-arm/…`.
public enum AntigravityUpdateParser {
    private struct Payload: Decodable {
        let url: String?
    }

    /// Extracts the Antigravity product version (e.g. `2.0.1`) from a raw
    /// update-API JSON response.
    public static func productVersion(fromUpdateJSON data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = payload.url else { return nil }
        return productVersion(fromDownloadURL: url)
    }

    /// Pulls the `X.Y.Z` segment that follows `/stable/` in the download URL,
    /// e.g. `…/antigravity/stable/2.0.1-4861014005645312/darwin-arm/…` → `2.0.1`.
    public static func productVersion(fromDownloadURL url: String) -> String? {
        guard let range = url.range(
            of: #"/stable/\d+(\.\d+)+"#,
            options: .regularExpression
        ) else { return nil }
        return url[range].split(separator: "/").last.map(String.init)
    }
}

/// Detects updates for the Antigravity IDE, whose Homebrew cask lags far
/// behind the app's real version (the cask is frozen while the app updates
/// itself). Queries Google's own update endpoint — the same one the app uses
/// to update itself — and compares the latest product version against the
/// installed bundle's `CFBundleShortVersionString`.
public struct AntigravityUpdateChecker: Sendable {
    /// Bundle identifier of `/Applications/Antigravity IDE.app`.
    ///
    /// Google ships two distinct products: "Antigravity" (`com.google.antigravity`)
    /// and "Antigravity IDE" (`com.google.antigravity-ide`). The update endpoint
    /// below serves the *IDE* — matching the plain `com.google.antigravity` app
    /// would flag it with the IDE's (unrelated) version.
    public static let bundleIdentifier = "com.google.antigravity-ide"

    private static let updateAPIBase =
        "https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/api/update"

    private let client: HTTPClient

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard app.bundleIdentifier == Self.bundleIdentifier,
              let installed = app.version, !installed.isEmpty else { return .notApplicable }

        let platform: String
        #if arch(arm64)
        platform = "darwin-arm64"
        #else
        platform = "darwin-x64"
        #endif

        guard let url = URL(string: "\(Self.updateAPIBase)/\(platform)/stable/latest") else { return .notApplicable }

        guard let response = try? await client.get(url, enableETag: true) else { return .failed }
        guard response.statusCode == 200,
              let latest = AntigravityUpdateParser.productVersion(fromUpdateJSON: response.data) else { return .failed }

        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version,
            availableVersion: latest,
            source: .antigravity
        ))
    }
}
