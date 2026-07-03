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
    public let postmanUpdate: String
    public let discordUpdate: String
    public let signalUpdate: String
    public let chromeVersions: String
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

    public func postmanUpdateURL(version: String) -> URL? {
        URL(string: Self.fill(postmanUpdate, ["version": version]))
    }

    public func githubReleasesPageURL(repo: String) -> URL? {
        URL(string: Self.fill(githubReleasesPage, ["repo": repo]))
    }

    public func discordUpdateURL(channel: String, version: String) -> URL? {
        URL(string: Self.fill(discordUpdate, ["channel": channel, "version": version]))
    }

    public func chromeVersionsURL(channel: String) -> URL? {
        URL(string: Self.fill(chromeVersions, ["channel": channel]))
    }

    // MARK: Fixed endpoints (force-unwrapped: the bundled config is validated at launch)

    public var chatgptAppcastURL: URL { URL(string: chatgptAppcast)! }
    public var signalUpdateURL: URL { URL(string: signalUpdate)! }
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
        // SEC-04: gdy publisher key jest skonfigurowany, overlay endpointów musi
        // mieć ważny odłączony podpis Ed25519 obok pliku (endpoints.json.sig) —
        // inaczej ignorujemy go (fail-closed). Bez klucza: zachowanie jak dotąd.
        if CatalogSignature.isConfigured {
            guard let data = try? Data(contentsOf: url),
                  let signature = try? String(contentsOf: url.appendingPathExtension("sig"), encoding: .utf8),
                  CatalogSignature.verify(data: data, signatureBase64: signature) else {
                return nil
            }
        }
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
        // DBT-5: stałe (nie-szablonowe) endpointy są force-unwrapowane w akcesorach
        // `…URL`, więc nadpisanie ich musi być POPRAWNYM URL-em — inaczej trzymamy
        // baseline (brak DoS przez crash / śmieciowy endpoint z niepoprawnego overlaya).
        //
        // ⚠️ macOS 14+ ma luźny `URL(string:)` (akceptuje m.in. spacje i stringi
        // bez schematu), więc samo `!= nil` NIE odsiewa śmieci. Walidujemy twardo
        // przez `URLComponents` (parser ścisły): wymóg absolutnego URL-a ze
        // schematem http(s) i niepustym hostem — wszystkie pola tu to https://…
        func validURL(_ override: String?, _ base: String) -> String {
            guard let override,
                  let comps = URLComponents(string: override),
                  let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = comps.host, !host.isEmpty
            else { return base }
            return override
        }
        // Szablonowe ({placeholder}) / komenda — akcesory zwracają Optional lub to
        // nie-URL, więc nie walidujemy jako URL (inaczej odrzucalibyśmy poprawne szablony).
        func raw(_ override: String?, _ base: String) -> String { override ?? base }

        return AppEndpoints(
            jetbrainsReleases: raw(other.jetbrainsReleases, jetbrainsReleases),
            chatgptAppcast: validURL(other.chatgptAppcast, chatgptAppcast),
            googleDriveOmaha: validURL(other.googleDriveOmaha, googleDriveOmaha),
            caskDatabase: validURL(other.caskDatabase, caskDatabase),
            appCatalog: validURL(other.appCatalog, appCatalog),
            githubLatestRelease: raw(other.githubLatestRelease, githubLatestRelease),
            synologyChangeLog: raw(other.synologyChangeLog, synologyChangeLog),
            antigravityUpdate: raw(other.antigravityUpdate, antigravityUpdate),
            parallelsUpdates: raw(other.parallelsUpdates, parallelsUpdates),
            postmanUpdate: raw(other.postmanUpdate, postmanUpdate),
            discordUpdate: raw(other.discordUpdate, discordUpdate),
            signalUpdate: validURL(other.signalUpdate, signalUpdate),
            chromeVersions: raw(other.chromeVersions, chromeVersions),
            homebrewWebsite: validURL(other.homebrewWebsite, homebrewWebsite),
            homebrewInstallCommand: raw(other.homebrewInstallCommand, homebrewInstallCommand),
            githubReleasesPage: raw(other.githubReleasesPage, githubReleasesPage),
            googleDriveDownload: validURL(other.googleDriveDownload, googleDriveDownload),
            projectRepository: validURL(other.projectRepository, projectRepository),
            projectIssues: validURL(other.projectIssues, projectIssues),
            authorLinkedIn: validURL(other.authorLinkedIn, authorLinkedIn),
            masRepository: validURL(other.masRepository, masRepository)
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
    public let postmanUpdate: String?
    public let discordUpdate: String?
    public let signalUpdate: String?
    public let chromeVersions: String?
    public let homebrewWebsite: String?
    public let homebrewInstallCommand: String?
    public let githubReleasesPage: String?
    public let googleDriveDownload: String?
    public let projectRepository: String?
    public let projectIssues: String?
    public let authorLinkedIn: String?
    public let masRepository: String?
}
