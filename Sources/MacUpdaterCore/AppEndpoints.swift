import Foundation

/// Every external URI Wega talks to, sourced from a customizable parameter
/// instead of being hard-coded at each call site.
///
/// The base/template strings live in `endpoints.json` (bundled with
/// `MacUpdaterCore`) and — like ``AppCatalog`` — may be overlaid by a
/// user-writable copy at
/// `~/Library/Application Support/WegaMacUpdater/endpoints.json`, so a vendor
/// that moves an update feed can be followed without shipping a new build.
///
/// Templated endpoints carry `{placeholder}` tokens (`{repo}`, `{code}`,
/// `{identify}`, `{platform}`, `{major}`) that the typed accessors below fill
/// in. Keeping the literal URIs in JSON (never in Swift) is what lets every
/// call site read its endpoint from configuration.
public struct AppEndpoints: Decodable, Sendable, Equatable {
    public let jetbrainsReleases: String
    public let chatgptAppcast: String
    public let googleDriveOmaha: String
    public let caskDatabase: String
    /// Canonical remote source for the `AppCatalog` overlay (`CatalogRefresher`).
    public let appCatalog: String
    public let githubLatestRelease: String
    public let synologyChangeLog: String
    public let antigravityUpdate: String
    public let parallelsUpdates: String
    public let homebrewWebsite: String
    public let homebrewInstallCommand: String
    public let githubReleasesPage: String
    public let googleDriveDownload: String
    public let projectRepository: String
    public let projectIssues: String
    public let authorLinkedIn: String
    public let masRepository: String

    private static func fill(_ template: String, _ tokens: [String: String]) -> String {
        tokens.reduce(template) { partial, pair in
            partial.replacingOccurrences(of: "{\(pair.key)}", with: pair.value)
        }
    }

    // MARK: Templated endpoints

    public func jetbrainsReleasesURL(code: String) -> URL? {
        URL(string: Self.fill(jetbrainsReleases, ["code": code]))
    }

    public func githubLatestReleaseURL(repo: String) -> URL? {
        URL(string: Self.fill(githubLatestRelease, ["repo": repo]))
    }

    public func synologyChangeLogURL(identify: String) -> URL? {
        URL(string: Self.fill(synologyChangeLog, ["identify": identify]))
    }

    public func antigravityUpdateURL(platform: String) -> URL? {
        URL(string: Self.fill(antigravityUpdate, ["platform": platform]))
    }

    public func parallelsUpdatesURL(major: Int) -> URL? {
        URL(string: Self.fill(parallelsUpdates, ["major": String(major)]))
    }

    public func githubReleasesPageURL(repo: String) -> URL? {
        URL(string: Self.fill(githubReleasesPage, ["repo": repo]))
    }

    // MARK: Fixed endpoints (force-unwrapped: the bundled config is validated at launch)

    public var chatgptAppcastURL: URL { URL(string: chatgptAppcast)! }
    public var googleDriveOmahaURL: URL { URL(string: googleDriveOmaha)! }
    public var caskDatabaseURL: URL { URL(string: caskDatabase)! }
    public var appCatalogURL: URL { URL(string: appCatalog)! }
    public var homebrewWebsiteURL: URL { URL(string: homebrewWebsite)! }
    public var googleDriveDownloadURL: URL { URL(string: googleDriveDownload)! }
    public var projectRepositoryURL: URL { URL(string: projectRepository)! }
    public var projectIssuesURL: URL { URL(string: projectIssues)! }
    public var authorLinkedInURL: URL { URL(string: authorLinkedIn)! }
    public var masRepositoryURL: URL { URL(string: masRepository)! }
}

// MARK: - Loading

extension AppEndpoints {
    /// Process-wide endpoints: the bundled baseline with the user overlay applied on top.
    public static let shared: AppEndpoints = loadShared()

    /// User-writable overlay location (refreshed out-of-band, e.g. from a remote fetch).
    public static var overlayURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("WegaMacUpdater", isDirectory: true)
            .appendingPathComponent("endpoints.json", isDirectory: false)
    }

    static func loadShared() -> AppEndpoints {
        guard let bundled = try? loadBundled() else {
            // The baseline resource ships inside the app bundle, so a failure here
            // is a build/packaging error, not a runtime condition to paper over.
            fatalError("endpoints.json is missing or malformed in the MacUpdaterCore bundle")
        }
        guard let overlay = loadOverlay() else { return bundled }
        return bundled.overlaying(overlay)
    }

    /// Decodes the JSON shipped inside `MacUpdaterCore`. Throws if the resource is
    /// missing or malformed — a contract the `AppEndpointsTests` suite guards.
    public static func loadBundled() throws -> AppEndpoints {
        guard let url = Bundle.module.url(forResource: "endpoints", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(contentsOf: url)
    }

    static func loadOverlay() -> AppEndpointsOverlay? {
        let url = overlayURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? decodeOverlay(contentsOf: url)
    }

    static func decode(contentsOf url: URL) throws -> AppEndpoints {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppEndpoints.self, from: data)
    }

    /// Returns a copy where any key present in `other` overrides this baseline.
    /// The overlay is decoded leniently (every field optional) so it may carry
    /// just the one endpoint a user wants to redirect.
    func overlaying(_ other: AppEndpointsOverlay) -> AppEndpoints {
        AppEndpoints(
            jetbrainsReleases: other.jetbrainsReleases ?? jetbrainsReleases,
            chatgptAppcast: other.chatgptAppcast ?? chatgptAppcast,
            googleDriveOmaha: other.googleDriveOmaha ?? googleDriveOmaha,
            caskDatabase: other.caskDatabase ?? caskDatabase,
            appCatalog: other.appCatalog ?? appCatalog,
            githubLatestRelease: other.githubLatestRelease ?? githubLatestRelease,
            synologyChangeLog: other.synologyChangeLog ?? synologyChangeLog,
            antigravityUpdate: other.antigravityUpdate ?? antigravityUpdate,
            parallelsUpdates: other.parallelsUpdates ?? parallelsUpdates,
            homebrewWebsite: other.homebrewWebsite ?? homebrewWebsite,
            homebrewInstallCommand: other.homebrewInstallCommand ?? homebrewInstallCommand,
            githubReleasesPage: other.githubReleasesPage ?? githubReleasesPage,
            googleDriveDownload: other.googleDriveDownload ?? googleDriveDownload,
            projectRepository: other.projectRepository ?? projectRepository,
            projectIssues: other.projectIssues ?? projectIssues,
            authorLinkedIn: other.authorLinkedIn ?? authorLinkedIn,
            masRepository: other.masRepository ?? masRepository
        )
    }

    static func decodeOverlay(contentsOf url: URL) throws -> AppEndpointsOverlay {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppEndpointsOverlay.self, from: data)
    }
}

/// Lenient counterpart of ``AppEndpoints`` used for the user overlay: every key
/// is optional so the file may redirect a single endpoint.
public struct AppEndpointsOverlay: Decodable, Sendable, Equatable {
    public let jetbrainsReleases: String?
    public let chatgptAppcast: String?
    public let googleDriveOmaha: String?
    public let caskDatabase: String?
    public let appCatalog: String?
    public let githubLatestRelease: String?
    public let synologyChangeLog: String?
    public let antigravityUpdate: String?
    public let parallelsUpdates: String?
    public let homebrewWebsite: String?
    public let homebrewInstallCommand: String?
    public let githubReleasesPage: String?
    public let googleDriveDownload: String?
    public let projectRepository: String?
    public let projectIssues: String?
    public let authorLinkedIn: String?
    public let masRepository: String?
}
