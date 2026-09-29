import Foundation

/// Parses ChatGPT desktop's public Sparkle appcast. OpenAI ships
/// `Sparkle.framework` but sets the feed URL programmatically at runtime —
/// `SUFeedURL` is absent from both `Info.plist` and the `com.openai.chat`
/// preferences domain — so the generic `SparkleUpdateChecker` can't discover
/// it. The feed lives under the app's internal codename "sidekick".
///
/// The feed items are NOT reliably ordered: older builds can carry a more
/// recent `pubDate` than the newest version (Homebrew's `chatgpt` cask warns
/// about this too). Item selection uses the shared Sparkle build ordering.
public enum ChatGPTUpdateParser {

    /// The display version of the newest appcast item; retained for existing callers.
    public static func latestVersion(fromAppcast data: Data) -> String? {
        AppcastParser.parse(data: data)
    }
}

/// Detects updates for the ChatGPT desktop app, whose Homebrew cask `chatgpt`
/// is marked `auto_updates` and whose metadata lags OpenAI's public release
/// channel by days. The app self-updates via Sparkle from a runtime-resolved
/// feed, so neither brew nor the generic Sparkle path surfaces the newer build.
/// Queries OpenAI's public appcast with the same build semantics as the generic checker.
public struct ChatGPTUpdateChecker: VendorUpdateChecker {
    /// Bundle identifier of `/Applications/ChatGPT.app`.
    public static let bundleIdentifier = "com.openai.chat"

    /// Public Sparkle appcast OpenAI ships for the desktop app (codename
    /// "sidekick"). Same feed Homebrew's `chatgpt` cask uses for livecheck.
    public static let appcastURL = AppEndpoints.shared.chatgptAppcastURL

    public let client: HTTPClient

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard app.bundleIdentifier == Self.bundleIdentifier,
              app.version?.isEmpty == false || app.buildVersion?.isEmpty == false else { return nil }

        return VendorCheckPlan(request: HTTPRequest(url: Self.appcastURL, enableETag: true)) { data in
            SparkleUpdateChecker.evaluate(data: data, app: app, source: .chatgpt)
        }
    }
}
