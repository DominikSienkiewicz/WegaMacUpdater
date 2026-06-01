import Foundation

/// Hits Google's Omaha update endpoint the same way GoogleSoftwareUpdate's
/// Keystone agent does, with the `com.google.drivefs` appid pinned to the
/// `canary` cohort. The Stable / 50-percent / 5-percent cohorts return the
/// staged-rollout version, which is often older than what's actually
/// installed (Drive's CFBundleVersion races ahead of stable); canary tracks
/// the head and is what other Mac update apps query to surface patches like
/// `126.0.4 → 126.0.5` that the public release-notes page never lists.
public enum GoogleDriveUpdateParser {

    public static let omahaEndpoint = URL(string: "https://tools.google.com/service/update2")!

    /// Build the Omaha v3 request body. The `version` attribute is what
    /// Omaha compares against the cohort head to decide ok vs noupdate.
    public static func omahaRequestBody(installedVersion: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>\
        <request protocol="3.0" updater="KeystoneDaemon-1.3.21.0" ismachine="0">\
        <os platform="mac" version="14.0" arch="arm64"/>\
        <app appid="com.google.drivefs" version="\(installedVersion)" lang="en-US" ap="canary">\
        <updatecheck/>\
        </app>\
        </request>
        """
    }

    /// Parses the `<manifest version="X.Y.Z.W"/>` element nested inside the
    /// `<updatecheck>` of an Omaha response. Returns nil when Omaha said
    /// `status="noupdate"` (no manifest emitted) or the XML is malformed.
    public static func latestVersion(fromOmahaResponse data: Data) -> String? {
        let delegate = ManifestParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.found
    }

    private final class ManifestParser: NSObject, XMLParserDelegate {
        var found: String?
        func parser(_ p: XMLParser,
                    didStartElement element: String,
                    namespaceURI: String?,
                    qualifiedName: String?,
                    attributes: [String: String]) {
            if element == "manifest", let v = attributes["version"], !v.isEmpty {
                found = v
                p.abortParsing()
            }
        }
    }
}

/// Detects updates for Google Drive for Desktop by speaking the same Omaha
/// protocol Keystone uses. Compares the manifest version Omaha returns
/// against the installed `CFBundleVersion`.
public struct GoogleDriveUpdateChecker: Sendable {
    public static let bundleIdentifier = "com.google.drivefs"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(app: ApplicationInfo) async -> ManualOutdatedApp? {
        guard app.bundleIdentifier == Self.bundleIdentifier else { return nil }
        // Prefer CFBundleVersion when available (Drive's 4-segment build
        // number, e.g. 126.0.4.0); fall back to CFBundleShortVersionString
        // (`126.0`). Omaha compares lexicographically so the short form
        // would always read as "older" and produce a false positive when
        // Drive is genuinely up to date.
        let installed = bundleVersion(at: app.path) ?? app.version ?? ""
        guard !installed.isEmpty else { return nil }

        var request = URLRequest(url: GoogleDriveUpdateParser.omahaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(GoogleDriveUpdateParser.omahaRequestBody(installedVersion: installed).utf8)
        request.cachePolicy = .reloadRevalidatingCacheData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = GoogleDriveUpdateParser.latestVersion(fromOmahaResponse: data),
              isUpgrade(installed: installed, latest: latest) else { return nil }

        return ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version ?? installed,
            availableVersion: latest,
            source: .googleDrive
        )
    }

    private func bundleVersion(at appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleVersion"] as? String
    }
}
