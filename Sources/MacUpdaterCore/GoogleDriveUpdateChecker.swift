import Foundation

/// Hits Google's Omaha update endpoint the same way GoogleSoftwareUpdate's
/// Keystone agent does, with the `com.google.drivefs` appid pinned to the
/// `canary` cohort. The Stable / 50-percent / 5-percent cohorts return the
/// staged-rollout version, which is often older than what's actually
/// installed (Drive's CFBundleVersion races ahead of stable); canary tracks
/// the head and is what other Mac update apps query to surface patches like
/// `126.0.4 → 126.0.5` that the public release-notes page never lists.
public enum GoogleDriveUpdateParser {

    public static let omahaEndpoint = AppEndpoints.shared.googleDriveOmahaURL

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
                    namespaceURI _: String?,
                    qualifiedName _: String?,
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
public struct GoogleDriveUpdateChecker: VendorUpdateChecker {
    public static let bundleIdentifier = "com.google.drivefs"

    public let client: HTTPClient

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard app.bundleIdentifier == Self.bundleIdentifier else { return nil }
        // Prefer CFBundleVersion when available (Drive's 4-segment build
        // number, e.g. 126.0.4.0); fall back to CFBundleShortVersionString
        // (`126.0`). Omaha compares lexicographically so the short form
        // would always read as "older" and produce a false positive when
        // Drive is genuinely up to date.
        let installed = bundleVersion(at: app.path) ?? app.version ?? ""
        guard !installed.isEmpty else { return nil }
        let recordedInstalled = app.version ?? installed

        let body = Data(GoogleDriveUpdateParser.omahaRequestBody(installedVersion: installed).utf8)
        let request = HTTPRequest(
            url: GoogleDriveUpdateParser.omahaEndpoint,
            method: "POST",
            headers: ["Content-Type": "application/xml"],
            body: body
        )
        return VendorCheckPlan(request: request) { data in
            // Omaha omits <manifest> when there's no update (status="noupdate"), so a
            // missing version here means "current", not a failure.
            guard let latest = GoogleDriveUpdateParser.latestVersion(fromOmahaResponse: data) else { return .decided(.upToDate) }
            return .candidate(VendorCandidate(latest: latest, installed: installed, recordedInstalled: recordedInstalled, source: .googleDrive))
        }
    }

    private func bundleVersion(at appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleVersion"] as? String
    }
}
