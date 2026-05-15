import Foundation

public struct SparkleUpdateChecker: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns a ManualOutdatedApp if the app has a Sparkle feed with a newer version.
    public func check(app: ApplicationInfo) async -> ManualOutdatedApp? {
        guard let bundle = Bundle(url: app.path),
              let feedString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feedString) else { return nil }

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
}

// MARK: - Appcast XML parser

private final class AppcastParser: NSObject, XMLParserDelegate {
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
