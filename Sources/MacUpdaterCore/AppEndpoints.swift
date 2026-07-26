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
    public let obsidianDesktopReleases: String
    public let homebrewWebsite: String
    public let homebrewInstallCommand: String
    public let githubReleasesPage: String
    public let googleDriveDownload: String
    public let projectRepository: String
    public let projectIssues: String
    /// Prefilled "new issue" endpoint the UX-14 Inventory report button targets via
    /// ``CatalogIssueBuilder``.
    public let projectNewIssue: String
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
    public var obsidianDesktopReleasesURL: URL { URL(string: obsidianDesktopReleases)! }
    public var googleDriveOmahaURL: URL { URL(string: googleDriveOmaha)! }
    public var caskDatabaseURL: URL { URL(string: caskDatabase)! }
    public var appCatalogURL: URL { URL(string: appCatalog)! }
    public var homebrewWebsiteURL: URL { URL(string: homebrewWebsite)! }
    public var googleDriveDownloadURL: URL { URL(string: googleDriveDownload)! }
    public var projectRepositoryURL: URL { URL(string: projectRepository)! }
    public var projectIssuesURL: URL { URL(string: projectIssues)! }
    public var projectNewIssueURL: URL { URL(string: projectNewIssue)! }
    public var authorLinkedInURL: URL { URL(string: authorLinkedIn)! }
    public var masRepositoryURL: URL { URL(string: masRepository)! }
}

/// Whether a user endpoints overlay is currently shaping these endpoints, and whether it was
/// cryptographically verified. Surfaced by ``AppEndpoints/overlayStatus`` so the Info card can
/// show the presence of an *unverified* overlay to the user — SEC-08 requires that this is not
/// signalled by a `log.warning` alone.
public enum EndpointsOverlayStatus: Sendable, Equatable {
    /// No overlay is in effect: either no file on disk, or a present-but-mis-signed file that was
    /// rejected (the bundled baseline endpoints are used).
    case absent
    /// An overlay is applied and a valid detached signature verified its bytes.
    case appliedVerified
    /// An overlay is applied without verification (unsigned, by policy). The state the Info card
    /// warns about.
    case appliedUnverified

    /// True only for ``appliedUnverified`` — the one state worth surfacing to the user.
    public var isUnverifiedOverlayActive: Bool { self == .appliedUnverified }
}

// MARK: - Loading

extension AppEndpoints {
    /// The bundled baseline with the user overlay applied on top, resolved once at launch,
    /// paired with the trust status of any overlay that shaped it.
    struct Resolved: Sendable {
        let endpoints: AppEndpoints
        let overlayStatus: EndpointsOverlayStatus
    }

    private static let resolved: Resolved = resolve()

    /// Process-wide endpoints: the bundled baseline with the user overlay applied on top.
    public static var shared: AppEndpoints { resolved.endpoints }

    /// SEC-08: whether a user overlay is shaping these endpoints and whether it was verified.
    /// The Info card reads this to surface an unverified overlay to the user — not only in the log.
    public static var overlayStatus: EndpointsOverlayStatus { resolved.overlayStatus }

    /// User-writable overlay location (refreshed out-of-band, e.g. from a remote fetch).
    public static var overlayURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("WegaMacUpdater", isDirectory: true)
            .appendingPathComponent("endpoints.json", isDirectory: false)
    }

    static func resolve() -> Resolved {
        guard let bundled = try? loadBundled() else {
            // The baseline resource ships inside the app bundle, so a failure here
            // is a build/packaging error, not a runtime condition to paper over.
            fatalError("endpoints.json is missing or malformed in the MacUpdaterCore bundle")
        }
        let (overlay, status) = loadOverlay()
        guard let overlay else { return Resolved(endpoints: bundled, overlayStatus: status) }
        return Resolved(endpoints: bundled.overlaying(overlay), overlayStatus: status)
    }

    /// Decodes the JSON shipped inside `MacUpdaterCore`. Throws if the resource is
    /// missing or malformed — a contract the `AppEndpointsTests` suite guards.
    public static func loadBundled() throws -> AppEndpoints {
        guard let url = Bundle.module.url(forResource: "endpoints", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(contentsOf: url)
    }

    /// Maps an overlay's on-disk trust inputs to the status the Info card shows. Kept free of IO
    /// so the signal is unit-testable without touching the real Application Support overlay path.
    /// `.absent` means no overlay is in effect (no file, or a present-but-mis-signed one that was
    /// rejected). Verified means an actual valid signature vouched for the bytes; anything applied
    /// without that — unsigned, or with signing not configured — is reported as unverified.
    static func resolveOverlayStatus(
        fileExists: Bool,
        signaturePresent: Bool,
        signatureValid: Bool,
        signingConfigured: Bool
    ) -> EndpointsOverlayStatus {
        guard fileExists else { return .absent }
        let decision = ConfigOverlayTrust.forEndpoints(
            signingConfigured: signingConfigured,
            signature: signaturePresent ? "" : nil,
            isValid: signatureValid
        )
        guard decision.appliesOverlay else { return .absent }
        return (signaturePresent && signatureValid) ? .appliedVerified : .appliedUnverified
    }

    static func loadOverlay() -> (overlay: AppEndpointsOverlay?, status: EndpointsOverlayStatus) {
        let url = overlayURL
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, .absent) }

        // SEC-04 / F5(a): this file is one the user places on their own disk to follow a feed
        // a vendor has moved, without waiting for a release. A signature would protect
        // nothing — whoever can write here can already do worse — so an unsigned overlay is
        // applied and logged. A signature that is present and *wrong*, however, means
        // tampering, and is refused. See `ConfigOverlayTrust.forEndpoints`.
        //
        // SEC-08: the trust status travels with the overlay so the Info card can surface an
        // unverified (unsigned) overlay, and every field of the applied overlay is validated or
        // excluded in `overlaying(_:)` — the whole config channel is fail-closed, not just the catalog.
        let signature = try? String(contentsOf: url.appendingPathExtension("sig"), encoding: .utf8)
        let isValid = signature.map { candidate in
            (try? Data(contentsOf: url)).map { CatalogSignature.verify(data: $0, signatureBase64: candidate) } ?? false
        } ?? false

        let status = resolveOverlayStatus(
            fileExists: true,
            signaturePresent: signature != nil,
            signatureValid: isValid,
            signingConfigured: CatalogSignature.isConfigured
        )

        switch status {
        case .absent:
            // File present but rejected: a signature is present and wrong (tampering) → fall back.
            WegaLog.error(.app, "endpoints.json: podpis obecny, ale nieprawidłowy — overlay zignorowany.")
            return (nil, .absent)
        case .appliedUnverified:
            WegaLog.warning(.app, "endpoints.json: overlay bez podpisu — zastosowany zgodnie z polityką, ale nieweryfikowany. Sygnalizowane w karcie Info.")
            guard let overlay = try? decodeOverlay(contentsOf: url) else { return (nil, .absent) }
            return (overlay, .appliedUnverified)
        case .appliedVerified:
            guard let overlay = try? decodeOverlay(contentsOf: url) else { return (nil, .absent) }
            return (overlay, .appliedVerified)
        }
    }

    static func decode(contentsOf url: URL) throws -> AppEndpoints {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppEndpoints.self, from: data)
    }

    /// Returns a copy where any key present in `other` overrides this baseline.
    /// The overlay is decoded leniently (every field optional) so it may carry
    /// just the one endpoint a user wants to redirect.
    ///
    /// SEC-08 — the whole config channel is fail-closed, so every override is validated or
    /// dropped before it can take effect:
    ///   • fixed endpoints keep `validURL` (absolute http(s) URL with a host);
    ///   • templated endpoints (`{placeholder}` tokens) additionally require **https** and a
    ///     **host on the allowlist** the bundled baseline already talks to — an override that
    ///     leaves that set, or downgrades to http, silently falls back to the baseline;
    ///   • the Homebrew install command is a shell string (surfaced as a copy button), so it is
    ///     **excluded from the overlay entirely** and always taken from the bundled baseline.
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

        // SEC-08: the hosts the bundled baseline already talks to — the allowlist template
        // overrides are held to. Derived from `self` (the baseline) so it can never drift out of
        // sync with the shipped endpoints; the shell command contributes no host and drops out.
        let allowedHosts: Set<String> = Set(
            Mirror(reflecting: self).children
                .compactMap { $0.value as? String }
                .compactMap(Self.templateHost)
        )

        // SEC-08: templated ({placeholder}) endpoints are fetched by the checkers, so an override
        // must be https AND land on an allowlisted host; otherwise keep the baseline template. The
        // strict `URLComponents` parser rejects the raw `{ }` characters, so placeholders are
        // neutralised before parsing (they always sit in the path/query, never the scheme/host).
        func templateURL(_ override: String?, _ base: String) -> String {
            guard let override,
                  let comps = URLComponents(string: Self.stripPlaceholders(override)),
                  comps.scheme?.lowercased() == "https",
                  let host = comps.host?.lowercased(), !host.isEmpty,
                  allowedHosts.contains(host)
            else { return base }
            return override
        }

        return AppEndpoints(
            jetbrainsReleases: templateURL(other.jetbrainsReleases, jetbrainsReleases),
            chatgptAppcast: validURL(other.chatgptAppcast, chatgptAppcast),
            googleDriveOmaha: validURL(other.googleDriveOmaha, googleDriveOmaha),
            caskDatabase: validURL(other.caskDatabase, caskDatabase),
            appCatalog: validURL(other.appCatalog, appCatalog),
            githubLatestRelease: templateURL(other.githubLatestRelease, githubLatestRelease),
            synologyChangeLog: templateURL(other.synologyChangeLog, synologyChangeLog),
            antigravityUpdate: templateURL(other.antigravityUpdate, antigravityUpdate),
            parallelsUpdates: templateURL(other.parallelsUpdates, parallelsUpdates),
            postmanUpdate: templateURL(other.postmanUpdate, postmanUpdate),
            discordUpdate: templateURL(other.discordUpdate, discordUpdate),
            signalUpdate: validURL(other.signalUpdate, signalUpdate),
            chromeVersions: templateURL(other.chromeVersions, chromeVersions),
            obsidianDesktopReleases: validURL(other.obsidianDesktopReleases, obsidianDesktopReleases),
            homebrewWebsite: validURL(other.homebrewWebsite, homebrewWebsite),
            // SEC-08: the install command is a shell string, never overridable from the overlay.
            homebrewInstallCommand: homebrewInstallCommand,
            githubReleasesPage: templateURL(other.githubReleasesPage, githubReleasesPage),
            googleDriveDownload: validURL(other.googleDriveDownload, googleDriveDownload),
            projectRepository: validURL(other.projectRepository, projectRepository),
            projectIssues: validURL(other.projectIssues, projectIssues),
            projectNewIssue: validURL(other.projectNewIssue, projectNewIssue),
            authorLinkedIn: validURL(other.authorLinkedIn, authorLinkedIn),
            masRepository: validURL(other.masRepository, masRepository)
        )
    }

    /// Replaces `{placeholder}` tokens with a neutral, URL-safe character so a template string can
    /// be run through the strict `URLComponents` parser (which rejects the raw `{ }` characters).
    static func stripPlaceholders(_ string: String) -> String {
        string.replacingOccurrences(of: #"\{[^{}]*\}"#, with: "0", options: .regularExpression)
    }

    /// The lowercased host of an endpoint string that may contain `{placeholder}` tokens, or nil
    /// for a non-URL string (e.g. the shell install command). Used to build the SEC-08 host
    /// allowlist from the bundled baseline.
    static func templateHost(_ endpoint: String) -> String? {
        guard let comps = URLComponents(string: stripPlaceholders(endpoint)),
              let host = comps.host, !host.isEmpty
        else { return nil }
        return host.lowercased()
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
    public var obsidianDesktopReleases: String? = nil
    public let homebrewWebsite: String?
    public let homebrewInstallCommand: String?
    public let githubReleasesPage: String?
    public let googleDriveDownload: String?
    public let projectRepository: String?
    public let projectIssues: String?
    // Defaulted (like `obsidianDesktopReleases`) so existing memberwise-init call sites keep
    // compiling without listing this UX-14 key.
    public var projectNewIssue: String? = nil
    public let authorLinkedIn: String?
    public let masRepository: String?
}
