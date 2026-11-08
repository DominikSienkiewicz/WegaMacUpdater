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

/// The Sparkle feed of the current ChatGPT for macOS (`com.openai.codex`, built on Codex),
/// which OpenAI releases in stages. Its static appcast (the catalog's Sparkle override)
/// lists a release as soon as the first rollout group gets it. The app itself asks
/// `updates.oaistatic.com/codex/app/appcast`, which redirects to the appcast that ends at
/// the release served to that installation. On 2026-11-08 every sampled installation with
/// no known plan was sent the release served to everyone, so the endpoint template carries
/// a placeholder installation ID and `plan_type=unknown`, never the user's own ID or plan.
public enum ChatGPTRolloutFeed {
    public static let bundleIdentifier = "com.openai.codex"

    /// Nil unless `installedVersion` is the dotted numeric version the endpoint expects.
    public static func url(installedVersion: String?) -> URL? {
        guard let installedVersion,
              installedVersion.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil else { return nil }
        return AppEndpoints.shared.chatgptRolloutAppcastURL(architecture: hostArchitecture, version: installedVersion)
    }

    private static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
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
