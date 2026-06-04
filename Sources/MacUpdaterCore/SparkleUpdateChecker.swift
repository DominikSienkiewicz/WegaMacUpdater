import Foundation

public struct SparkleUpdateChecker: Sendable {
    private let session: URLSession
    private let feedOverrides: [String: String]

    public init(session: URLSession = .shared, feedOverrides: [String: String] = SparkleFeedOverrides.defaults) {
        self.session = session
        self.feedOverrides = feedOverrides
    }

    /// Returns a ManualOutdatedApp if the app has a Sparkle feed with a newer version.
    public func check(app: ApplicationInfo) async -> ManualOutdatedApp? {
        let feedURL = resolveFeedURL(for: app)
        guard let feedURL else { return nil }

        guard let (data, response) = try? await session.data(from: feedURL),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        guard let latest = AppcastParser.parse(data: data) else { return nil }

        let installed = app.version ?? ""
        guard !installed.isEmpty, latest != installed else { return nil }

        return ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version,
            availableVersion: latest,
            source: .sparkle
        )
    }

    /// Lookup order, first hit wins:
    /// 1. `SparkleFeedOverrides` (hard-coded for apps that hide the URL — e.g. Electron-based Codex).
    /// 2. App's UserDefaults `SUFeedURL` (Sparkle reads this at runtime; some apps set it for beta/stable channels).
    /// 3. `Info.plist:SUFeedURL` read via PropertyListSerialization — never `Bundle(url:)`, which caches
    ///    plist values across in-place updates and returns stale data.
    private func resolveFeedURL(for app: ApplicationInfo) -> URL? {
        if let bundleID = app.bundleIdentifier,
           let override = feedOverrides[bundleID],
           let url = URL(string: override) {
            return url
        }
        if let bundleID = app.bundleIdentifier,
           let defaultsURL = feedURLFromUserDefaults(bundleID: bundleID) {
            return defaultsURL
        }
        return feedURLFromInfoPlist(at: app.path)
    }

    private func feedURLFromUserDefaults(bundleID: String) -> URL? {
        guard let raw = CFPreferencesCopyAppValue("SUFeedURL" as CFString, bundleID as CFString),
              let string = raw as? String,
              let url = URL(string: string) else { return nil }
        return url
    }

    private func feedURLFromInfoPlist(at appURL: URL) -> URL? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let feedString = plist["SUFeedURL"] as? String,
              let url = URL(string: feedString) else { return nil }
        return url
    }
}

/// Hard-coded Sparkle feed URLs for apps that don't expose `SUFeedURL` via Info.plist.
/// Add new entries here when you discover an app that ships Sparkle but configures the feed at runtime.
public enum SparkleFeedOverrides {
    /// Hard-coded feed URLs for apps that hide `SUFeedURL` (e.g. Electron-based Codex,
    /// which sets it in JS at runtime). Sourced from the shared `AppCatalog`.
    public static var defaults: [String: String] {
        AppCatalog.shared.sparkleFeedOverridesByBundleID
    }
}

// MARK: - Appcast XML parser

final class AppcastParser: NSObject, XMLParserDelegate {
    private var found: String?
    private var inItem = false
    private var seenItem = false
    private var currentChars = ""

    static func parse(data: Data) -> String? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.found
    }

    func parser(
        _ p: XMLParser,
        didStartElement el: String,
        namespaceURI: String?,
        qualifiedName _: String?,
        attributes attrs: [String: String]
    ) {
        if el == "item" { inItem = true }
        if inItem && !seenItem && el == "enclosure" {
            if let v = attrs["sparkle:shortVersionString"] ?? attrs["sparkle:version"] {
                found = v; seenItem = true; p.abortParsing()
            }
        }
        currentChars = ""
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { currentChars += s }

    func parser(
        _ p: XMLParser,
        didEndElement el: String,
        namespaceURI: String?,
        qualifiedName _: String?
    ) {
        let trimmed = currentChars.trimmingCharacters(in: .whitespacesAndNewlines)
        // Handle both "sparkle:shortVersionString" and plain "shortVersionString" (namespace-unaware parsers)
        let local = el.components(separatedBy: ":").last ?? el
        if inItem && !seenItem && local == "shortVersionString" && !trimmed.isEmpty {
            found = trimmed; seenItem = true
        }
        if el == "item" {
            if seenItem { p.abortParsing() }
            inItem = false
        }
        currentChars = ""
    }
}
