import Foundation

public struct SparkleUpdateChecker: Sendable {
    private let client: HTTPClient
    private let feedOverrides: [String: String]

    public init(client: HTTPClient = .shared, feedOverrides: [String: String] = SparkleFeedOverrides.defaults) {
        self.client = client
        self.feedOverrides = feedOverrides
    }

    /// Returns the update status for an app that exposes a Sparkle feed.
    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        let feedURL = resolveFeedURL(for: app)
        guard let feedURL else { return .notApplicable }

        // SEC-09: a version check over plain HTTP is MITM-able (spoofed "outdated"
        // → user nudged to a malicious download page). Trust HTTPS feeds only.
        guard feedURL.scheme?.lowercased() == "https" else { return .notApplicable }

        guard let response = try? await client.get(feedURL, enableETag: true) else { return .unavailable }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let latest = AppcastParser.parse(data: response.data) else { return .failed }

        let installed = app.version ?? ""
        guard !installed.isEmpty else { return .notApplicable }
        guard latest != installed else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version,
            availableVersion: latest,
            source: .sparkle
        ))
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

/// The first appcast `<item>` that carries a version, decomposed into the fields the
/// release-notes UI needs. `descriptionHTML` is the raw `<description>` payload (often
/// HTML, often CDATA) handed back untouched — sanitizing / AttributedString conversion
/// is a UI concern, not the parser's. `releaseNotesLink` obeys SEC-09: HTTPS only.
struct AppcastItem: Equatable {
    var version: String?
    var descriptionHTML: String?
    var releaseNotesLink: URL?
}

final class AppcastParser: NSObject, XMLParserDelegate {
    private var version: String?
    private var descriptionHTML: String?
    private var releaseNotesLink: URL?
    private var inItem = false
    private var enclosureVersionFound = false
    private var currentChars = ""

    /// Backward-compatible entry point: the latest version string only.
    static func parse(data: Data) -> String? {
        parseItem(data: data)?.version
    }

    /// Full first-versioned-item extraction: version + release notes. `nil` when no
    /// item carries a version — mirroring `parse`'s nil contract exactly.
    static func parseItem(data: Data) -> AppcastItem? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let version = delegate.version else { return nil }
        return AppcastItem(
            version: version,
            descriptionHTML: delegate.descriptionHTML,
            releaseNotesLink: delegate.releaseNotesLink
        )
    }

    func parser(
        _: XMLParser,
        didStartElement el: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attrs: [String: String]
    ) {
        if el == "item" { inItem = true }
        // Handle both "sparkle:…" and plain (namespace-unaware) local names.
        let local = el.components(separatedBy: ":").last ?? el
        if inItem, !enclosureVersionFound, local == "enclosure",
           let v = attrs["sparkle:shortVersionString"] ?? attrs["sparkle:version"] {
            version = v; enclosureVersionFound = true
        }
        currentChars = ""
    }

    func parser(_: XMLParser, foundCharacters s: String) { currentChars += s }

    // `<description>` frequently wraps HTML in CDATA; XMLParser routes that here, not to
    // foundCharacters. Append the raw bytes so the markup survives verbatim.
    func parser(_: XMLParser, foundCDATA block: Data) {
        currentChars += String(decoding: block, as: UTF8.self)
    }

    func parser(
        _ p: XMLParser,
        didEndElement el: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        let trimmed = currentChars.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = el.components(separatedBy: ":").last ?? el
        if inItem {
            switch local {
            case "shortVersionString":
                if version == nil, !trimmed.isEmpty { version = trimmed }
            case "description":
                if descriptionHTML == nil, !trimmed.isEmpty { descriptionHTML = trimmed }
            case "releaseNotesLink":
                // SEC-09: a plain-HTTP notes link is MITM-able — trust HTTPS only.
                if releaseNotesLink == nil, let url = URL(string: trimmed),
                   url.scheme?.lowercased() == "https" {
                    releaseNotesLink = url
                }
            default:
                break
            }
        }
        if el == "item" {
            if version != nil {
                // First versioned item wins; stop before later items overwrite it.
                p.abortParsing()
            } else {
                // Version-less item: discard its notes and keep scanning (a later item
                // may carry the version — preserving the original lookup contract).
                descriptionHTML = nil
                releaseNotesLink = nil
                enclosureVersionFound = false
            }
            inItem = false
        }
        currentChars = ""
    }
}
