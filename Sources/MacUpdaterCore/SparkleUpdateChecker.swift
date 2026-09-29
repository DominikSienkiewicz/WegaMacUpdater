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
            Self.evaluate(data: data, app: app, source: .sparkle)
        }
    }

    static func evaluate(data: Data, app: ApplicationInfo, source: ManualOutdatedApp.UpdateSource) -> VendorEvaluation {
        guard let result = AppcastParser.parseResult(
            data: data, installedVersion: app.version ?? "", installedBuildVersion: app.buildVersion
        ), let latest = result.latest.comparisonVersion(usingBuild: result.usesBuildVersion)
        else { return .decided(.failed) }
        let installed = (result.usesBuildVersion ? app.buildVersion : app.version) ?? ""
        guard !installed.isEmpty else { return .decided(.notApplicable) }
        let scheme: VersionScheme = result.usesBuildVersion ? .numericBuild : .buildNumbered
        guard compareVersions(installed, latest, scheme: scheme) != .unknown else { return .decided(.failed) }
        return .candidate(VendorCandidate(
            latest: latest, installed: installed,
            recordedInstalled: AppcastItem.label(version: app.version, build: result.usesBuildVersion ? app.buildVersion : nil),
            source: source, releaseNotes: ReleaseNotes(history: result.history, link: result.latest.releaseNotesLink), scheme: scheme,
            recordedLatest: result.latest.label(includingBuild: result.usesBuildVersion),
            installedVersionField: result.usesBuildVersion ? .buildVersion : .shortVersion
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

/// The appcast `<item>` chosen for the update, decomposed into the fields the
/// release-notes UI needs. `descriptionHTML` is the raw `<description>` payload (often
/// HTML, often CDATA) handed back untouched — sanitizing / AttributedString conversion
/// is a UI concern, not the parser's. `releaseNotesLink` obeys SEC-09: HTTPS only.
struct AppcastItem: Equatable {
    var shortVersion: String?
    var buildVersion: String?
    var version: String? { shortVersion ?? buildVersion }
    var descriptionHTML: String?
    var releaseNotesLink: URL?
    /// RSS `<pubDate>` (RFC 822), when the feed carries one.
    var publishedAt: Date?

    func comparisonVersion(usingBuild: Bool) -> String? { usingBuild ? buildVersion : shortVersion }
    func label(includingBuild: Bool) -> String? {
        Self.label(version: version, build: includingBuild ? buildVersion : nil)
    }
    static func label(version: String?, build: String?) -> String? {
        guard let version else { return build }
        guard let build, build != version, !version.hasSuffix(" (\(build))") else { return version }
        return "\(version) (\(build))"
    }
}

/// What one appcast says: which item to offer, and everything published on the way to it.
struct AppcastResult: Equatable {
    var latest: AppcastItem
    var history: ReleaseHistory
    var usesBuildVersion: Bool
}

final class AppcastParser: NSObject, XMLParserDelegate {
    /// Every `<item>` that carried a version, in document order, with the channel it was
    /// published on — `nil` is Sparkle's default channel.
    private var items: [(item: AppcastItem, channel: String?)] = []
    private var shortVersion: String?
    private var buildVersion: String?
    private var enclosureShortVersion: String?
    private var enclosureBuildVersion: String?
    private var descriptionHTML: String?
    private var releaseNotesLink: URL?
    private var publishedAt: Date?
    private var channel: String?
    private var inItem = false
    private var elementStack: [String] = []
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
    static func candidates(data: Data) -> [AppcastItem] {
        parsedCandidates(data: data) ?? []
    }

    static func parsedCandidates(data: Data) -> [AppcastItem]? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
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
        let items = candidates(data: data)
        let usesBuild = items.contains { $0.buildVersion != nil }
        return items.filter { !usesBuild || $0.buildVersion != nil }.max { lhs, rhs in
            isUpgrade(installed: lhs.comparisonVersion(usingBuild: usesBuild) ?? "", latest: rhs.comparisonVersion(usingBuild: usesBuild) ?? "",
                      scheme: usesBuild ? .numericBuild : .buildNumbered)
        }
    }

    /// The chosen item plus every release published between `installedVersion` and it —
    /// the answer to *what do I get if I update*, which the newest item alone cannot give
    /// once more than one release has passed.
    ///
    /// Entries whose description collapses to nothing are left out rather than listed
    /// empty; `omitted` counts only what the cap dropped.
    static func parseResult(data: Data, installedVersion: String, limit: Int = 10, installedBuildVersion: String? = nil) -> AppcastResult? {
        let items = candidates(data: data)
        let usesBuild = installedBuildVersion?.isEmpty == false && items.contains { $0.buildVersion != nil }
        let comparable = items.filter { $0.comparisonVersion(usingBuild: usesBuild) != nil }
        let installed = usesBuild ? installedBuildVersion ?? "" : installedVersion
        let scheme: VersionScheme = usesBuild ? .numericBuild : .buildNumbered
        func version(_ item: AppcastItem) -> String { item.comparisonVersion(usingBuild: usesBuild) ?? "" }
        guard let latest = comparable.max(by: { isUpgrade(installed: version($0), latest: version($1), scheme: scheme) })
        else { return nil }

        let newer = comparable
            .filter { isUpgrade(installed: installed, latest: version($0), scheme: scheme) }
            .filter { !ReleaseNotesText.plain(fromHTML: $0.descriptionHTML ?? "").isEmpty }
            .sorted { compareVersions(version($0), version($1), scheme: scheme) == .orderedDescending }

        let kept = newer.prefix(limit).map { entry in
            ReleaseNote(
                version: entry.label(includingBuild: usesBuild) ?? "",
                publishedAt: entry.publishedAt,
                body: ReleaseNotesText.plain(fromHTML: entry.descriptionHTML ?? "")
            )
        }

        return AppcastResult(
            latest: latest,
            history: ReleaseHistory(notes: Array(kept), omitted: max(0, newer.count - kept.count)),
            usesBuildVersion: usesBuild
        )
    }

    func parser(
        _: XMLParser,
        didStartElement el: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attrs: [String: String]
    ) {
        let local = el.components(separatedBy: ":").last ?? el
        elementStack.append(local)
        if local == "item" {
            inItem = true
            shortVersion = nil
            buildVersion = nil
            enclosureShortVersion = nil
            enclosureBuildVersion = nil
            descriptionHTML = nil
            releaseNotesLink = nil
            publishedAt = nil
            channel = nil
        }
        if inItem, elementStack.dropLast().last == "item", local == "enclosure" {
            enclosureShortVersion = enclosureShortVersion ?? Self.nonempty(attrs["sparkle:shortVersionString"])
            enclosureBuildVersion = enclosureBuildVersion ?? Self.nonempty(attrs["sparkle:version"])
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
        defer { if !elementStack.isEmpty { elementStack.removeLast() } }
        if inItem, elementStack.dropLast().last == "item" {
            switch local {
            case "version":
                if buildVersion == nil { buildVersion = Self.nonempty(trimmed) }
            case "shortVersionString":
                if shortVersion == nil { shortVersion = Self.nonempty(trimmed) }
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
        if local == "item" {
            let shortVersion = shortVersion ?? enclosureShortVersion
            let buildVersion = buildVersion ?? enclosureBuildVersion
            if shortVersion != nil || buildVersion != nil {
                items.append((
                    AppcastItem(shortVersion: shortVersion, buildVersion: buildVersion, descriptionHTML: descriptionHTML,
                                releaseNotesLink: releaseNotesLink, publishedAt: publishedAt),
                    channel
                ))
            }
            inItem = false
        }
        currentChars = ""
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
