import Foundation

/// Parses Signal Desktop's `electron-updater` feed (`.../desktop/latest-mac.yml`),
/// whose first top-level `version:` line carries the latest version, e.g. `version: 7.68.0`.
public enum SignalUpdateParser {
    public static func latestVersion(fromYAML data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("version:") else { continue }
            let value = String(line.dropFirst("version:".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t'\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Detects updates for Signal Desktop, which self-updates via electron-updater (no
/// Sparkle `SUFeedURL`) while its `signal` cask is `auto_updates` and lags. Same
/// approach as Postman and ChatGPT.
public struct SignalUpdateChecker: VendorUpdateChecker {
    public static let bundleIdentifier = "org.whispersystems.signal-desktop"
    public static var updateURL: URL { AppEndpoints.shared.signalUpdateURL }

    public let client: HTTPClient
    public init(client: HTTPClient = .shared) { self.client = client }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard app.bundleIdentifier == Self.bundleIdentifier,
              let installed = app.version, !installed.isEmpty else { return nil }

        return VendorCheckPlan(request: HTTPRequest(url: Self.updateURL, enableETag: true)) { data in
            guard let latest = SignalUpdateParser.latestVersion(fromYAML: data) else { return .decided(.failed) }
            return .candidate(VendorCandidate(latest: latest, installed: installed, source: .signal))
        }
    }
}
