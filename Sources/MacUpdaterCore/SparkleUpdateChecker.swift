import Foundation

public struct SparkleUpdateChecker: VendorUpdateChecker {
    public let client: HTTPClient
    private let feedOverrides: [String: String]

    public init(client: HTTPClient = .shared, feedOverrides: [String: String] = SparkleFeedOverrides.defaults) {
        self.client = client
        self.feedOverrides = feedOverrides
    }

    /// Returns the plan for an app that exposes an HTTPS Sparkle feed, or nil when no feed
    /// resolves (or it isn't HTTPS) — in which case the checker makes no request.
    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard let feedURL = resolveFeedURL(for: app) else { return nil }

        // SEC-09: a version check over plain HTTP is MITM-able (spoofed "outdated"
        // → user nudged to a malicious download page). Trust HTTPS feeds only.
        guard feedURL.scheme?.lowercased() == "https" else { return nil }

        return VendorCheckPlan(request: HTTPRequest(url: feedURL, enableETag: true)) { data in
            guard let latest = AppcastParser.parse(data: data) else { return .decided(.failed) }

            let installed = app.version ?? ""
            guard !installed.isEmpty else { return .decided(.notApplicable) }
            // REL-10: compare versions, not strings. A plain `latest != installed` reports an
            // update whenever the feed lags behind the installed build, or merely formats the
            // version differently ("7.0.0" vs "7.0.0 (77593)") — both offer a downgrade.
            return .candidate(VendorCandidate(latest: latest, installed: installed, recordedInstalled: app.version, source: .sparkle))
        }
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

/// The appcast `<item>` chosen for the update, decomposed into the fields the
/// release-notes UI needs. `descriptionHTML` is the raw `<description>` payload (often
/// HTML, often CDATA) handed back untouched — sanitizing / AttributedString conversion
/// is a UI concern, not the parser's. `releaseNotesLink` obeys SEC-09: HTTPS only.
struct AppcastItem: Equatable {
    var version: String?
    var descriptionHTML: String?
    var releaseNotesLink: URL?
    /// RSS `<pubDate>` (RFC 822), when the feed carries one.
    var publishedAt: Date?
}

/// What one appcast says: which item to offer, and everything published on the way to it.
struct AppcastResult: Equatable {
    var latest: AppcastItem
    var history: ReleaseHistory
}

final class AppcastParser: NSObject, XMLParserDelegate {
    /// Every `<item>` that carried a version, in document order, with the channel it was
    /// published on — `nil` is Sparkle's default channel.
    private var items: [(item: AppcastItem, channel: String?)] = []
    private var version: String?
    private var descriptionHTML: String?
    private var releaseNotesLink: URL?
    private var publishedAt: Date?
    private var channel: String?
    private var inItem = false
    private var enclosureVersionFound = false
    private var currentChars = ""

    /// RSS dates are RFC 822. Fixed locale and zero time zone so a user's regional
    /// settings cannot change whether a feed's date parses.
    private static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func rfc822Date(from string: String) -> Date? {
        rfc822Formatter.date(from: string)
    }

    /// Backward-compatible entry point: the latest version string only.
    static func parse(data: Data) -> String? {
        parseItem(data: data)?.version
    }

    /// Every item Sparkle would offer this user: the default channel when the feed has one,
    /// otherwise all items. An item carrying `<sparkle:channel>` is offered by Sparkle only
    /// to users who opted into that channel.
    private static func candidates(data: Data) -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        let defaultChannel = delegate.items.filter { $0.channel == nil }
        return (defaultChannel.isEmpty ? delegate.items : defaultChannel).map(\.item)
    }

    /// The highest version among the items on Sparkle's default channel — never merely the
    /// first. Feeds are not reliably newest-first (`ChatGPTUpdateParser` exists for exactly
    /// that reason), and an item carrying `<sparkle:channel>` is offered by Sparkle only to
    /// users who opted into that channel, so such items are skipped unless the feed has no
    /// default-channel item at all. Incomparable versions keep document order. `nil` when
    /// no item carries a version — mirroring `parse`'s nil contract exactly.
    static func parseItem(data: Data) -> AppcastItem? {
        // max(by:) wants an ascending predicate: $0 precedes $1 when $1 is the newer version.
        candidates(data: data).max { lhs, rhs in
            isUpgrade(installed: lhs.version ?? "", latest: rhs.version ?? "")
        }
    }

    /// The chosen item plus every release published between `installedVersion` and it —
    /// the answer to *what do I get if I update*, which the newest item alone cannot give
    /// once more than one release has passed.
    ///
    /// Entries whose description collapses to nothing are left out rather than listed
    /// empty; `omitted` counts only what the cap dropped.
    static func parseResult(data: Data, installedVersion: String, limit: Int = 10) -> AppcastResult? {
        let items = candidates(data: data)
        guard let latest = items.max(by: { isUpgrade(installed: $0.version ?? "", latest: $1.version ?? "") })
        else { return nil }

        let newer = items
            .filter { isUpgrade(installed: installedVersion, latest: $0.version ?? "") }
            .filter { !ReleaseNotesText.plain(fromHTML: $0.descriptionHTML ?? "").isEmpty }
            // `compareVersions` takes no default scheme — appcasts are `.buildNumbered`,
            // the same scheme `isUpgrade(installed:latest:)` applies above.
            .sorted { compareVersions($0.version ?? "", $1.version ?? "", scheme: .buildNumbered) == .orderedDescending }

        let kept = newer.prefix(limit).map { entry in
            ReleaseNote(
                version: entry.version ?? "",
                publishedAt: entry.publishedAt,
                body: ReleaseNotesText.plain(fromHTML: entry.descriptionHTML ?? "")
            )
        }

        return AppcastResult(
            latest: latest,
            history: ReleaseHistory(notes: Array(kept), omitted: max(0, newer.count - kept.count))
        )
    }

    func parser(
        _: XMLParser,
        didStartElement el: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attrs: [String: String]
    ) {
        if el == "item" {
            inItem = true
            version = nil
            descriptionHTML = nil
            releaseNotesLink = nil
            publishedAt = nil
            channel = nil
            enclosureVersionFound = false
        }
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
        _: XMLParser,
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
            case "channel":
                // `<sparkle:channel>` inside an item. The RSS `<channel>` container closes
                // outside any item and never reaches this branch.
                if !trimmed.isEmpty { channel = trimmed }
            case "pubDate":
                if publishedAt == nil { publishedAt = Self.rfc822Date(from: trimmed) }
            default:
                break
            }
        }
        if el == "item" {
            if let version {
                items.append((
                    AppcastItem(version: version, descriptionHTML: descriptionHTML,
                                releaseNotesLink: releaseNotesLink, publishedAt: publishedAt),
                    channel
                ))
            }
            inItem = false
        }
        currentChars = ""
    }
}
