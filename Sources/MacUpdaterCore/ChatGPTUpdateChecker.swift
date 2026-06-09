import Foundation

/// Parses ChatGPT desktop's public Sparkle appcast. OpenAI ships
/// `Sparkle.framework` but sets the feed URL programmatically at runtime —
/// `SUFeedURL` is absent from both `Info.plist` and the `com.openai.chat`
/// preferences domain — so the generic `SparkleUpdateChecker` can't discover
/// it. The feed lives under the app's internal codename "sidekick".
///
/// The feed items are NOT reliably ordered: older builds can carry a more
/// recent `pubDate` than the newest version (Homebrew's `chatgpt` cask warns
/// about this too). So we take the max `sparkle:shortVersionString` across
/// every `<item>`, never just the first.
public enum ChatGPTUpdateParser {

    /// Returns the highest `sparkle:shortVersionString` across all `<item>`
    /// elements, or nil when the feed has no parseable item.
    public static func latestVersion(fromAppcast data: Data) -> String? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        // max(by:) wants an ascending predicate: $0 precedes $1 when $1 is the
        // newer version, i.e. $0 → $1 is an upgrade.
        return delegate.versions.max { isUpgrade(installed: $0, latest: $1) }
    }

    private final class AppcastParser: NSObject, XMLParserDelegate {
        var versions: [String] = []
        private var current = ""
        private var capturing = false

        func parser(_: XMLParser,
                    didStartElement element: String,
                    namespaceURI _: String?,
                    qualifiedName _: String?,
                    attributes _: [String: String]) {
            // Match both namespace-qualified and bare element names.
            let local = element.components(separatedBy: ":").last ?? element
            capturing = (local == "shortVersionString")
            current = ""
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            if capturing { current += string }
        }

        func parser(_: XMLParser,
                    didEndElement element: String,
                    namespaceURI _: String?,
                    qualifiedName _: String?) {
            let local = element.components(separatedBy: ":").last ?? element
            if local == "shortVersionString" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { versions.append(trimmed) }
            }
            capturing = false
            current = ""
        }
    }
}

/// Detects updates for the ChatGPT desktop app, whose Homebrew cask `chatgpt`
/// is marked `auto_updates` and whose metadata lags OpenAI's public release
/// channel by days. The app self-updates via Sparkle from a runtime-resolved
/// feed, so neither brew nor the generic Sparkle path surfaces the newer build.
/// Queries OpenAI's public appcast directly and compares the short version.
public struct ChatGPTUpdateChecker: Sendable {
    /// Bundle identifier of `/Applications/ChatGPT.app`.
    public static let bundleIdentifier = "com.openai.chat"

    /// Public Sparkle appcast OpenAI ships for the desktop app (codename
    /// "sidekick"). Same feed Homebrew's `chatgpt` cask uses for livecheck.
    public static let appcastURL = AppEndpoints.shared.chatgptAppcastURL

    private let client: HTTPClient

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard app.bundleIdentifier == Self.bundleIdentifier,
              let installed = app.version, !installed.isEmpty else { return .notApplicable }

        guard let response = try? await client.get(Self.appcastURL, enableETag: true) else { return .unavailable }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let latest = ChatGPTUpdateParser.latestVersion(fromAppcast: response.data) else { return .failed }

        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: installed,
            availableVersion: latest,
            source: .chatgpt
        ))
    }
}
