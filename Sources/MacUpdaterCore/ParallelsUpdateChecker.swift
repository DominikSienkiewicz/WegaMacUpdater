import Foundation

/// Parses Parallels Desktop's `parallels_updates.xml` payload served from
/// `update.parallels.com`. The vendor groups updates per major (v20, v26, …)
/// and the file contains a single `<Version>` block per release line.
public enum ParallelsUpdateParser {

    public struct LatestRelease: Equatable, Sendable {
        public let shortVersion: String
        public let build: String?

        public init(shortVersion: String, build: String?) {
            self.shortVersion = shortVersion
            self.build = build
        }
    }

    public static func latest(fromUpdatesXML data: Data) -> LatestRelease? {
        let delegate = VersionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    private final class VersionParser: NSObject, XMLParserDelegate {
        var result: LatestRelease?

        private var insideVersion = false
        private var current = ""
        private var major: String?
        private var minor: String?
        private var subMinor: String?
        private var subSubMinor: String?

        func parser(_ p: XMLParser,
                    didStartElement element: String,
                    namespaceURI: String?,
                    qualifiedName: String?,
                    attributes: [String: String]) {
            if element == "Version" { insideVersion = true }
            current = ""
        }

        func parser(_ p: XMLParser, foundCharacters string: String) {
            current += string
        }

        func parser(_ p: XMLParser,
                    didEndElement element: String,
                    namespaceURI: String?,
                    qualifiedName: String?) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if insideVersion {
                switch element {
                case "Major":       major = trimmed
                case "Minor":       minor = trimmed
                case "SubMinor":    subMinor = trimmed
                case "SubSubMinor": subSubMinor = trimmed
                case "Version":
                    if let mj = major, let mn = minor, let sm = subMinor {
                        result = LatestRelease(shortVersion: "\(mj).\(mn).\(sm)",
                                               build: subSubMinor)
                    }
                    insideVersion = false
                    p.abortParsing()
                default: break
                }
            }
            current = ""
        }
    }
}

/// Detects updates for Parallels Desktop, whose Homebrew cask `parallels` lags
/// upstream by days/weeks while the app self-updates from
/// `update.parallels.com`. Queries the vendor's own XML feed for the major
/// matching the installed bundle and compares the short version.
public struct ParallelsUpdateChecker: Sendable {
    /// Bundle identifier of `/Applications/Parallels Desktop.app`.
    public static let bundleIdentifier = "com.parallels.desktop.console"

    /// Builds the per-major endpoint, e.g.
    /// `https://update.parallels.com/desktop/v26/parallels/parallels_updates.xml`
    /// from an installed short version like `26.3.2`. Returns nil when the
    /// installed version has no parseable major.
    public static func updateURL(forShortVersion version: String) -> URL? {
        let head = version.split(separator: ".").first.map(String.init) ?? ""
        guard let major = Int(head), major > 0 else { return nil }
        return URL(string: "https://update.parallels.com/desktop/v\(major)/parallels/parallels_updates.xml")
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(app: ApplicationInfo) async -> ManualOutdatedApp? {
        guard app.bundleIdentifier == Self.bundleIdentifier,
              let installed = app.version, !installed.isEmpty,
              let url = Self.updateURL(forShortVersion: installed) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("WegaMacUpdater/1.0", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadRevalidatingCacheData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = ParallelsUpdateParser.latest(fromUpdatesXML: data),
              isUpgrade(installed: installed, latest: latest.shortVersion) else { return nil }

        return ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: installed,
            availableVersion: latest.shortVersion,
            source: .parallels
        )
    }
}
