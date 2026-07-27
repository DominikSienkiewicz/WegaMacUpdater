import Foundation

// MARK: - Catalog entries

/// One app the `GitHubReleasesChecker` knows how to track.
public struct GitHubCatalogEntry: Decodable, Sendable, Equatable {
    public let bundleId: String
    public let repo: String
    public let caskToken: String
}

/// One JetBrains IDE the `JetBrainsUpdateChecker` knows how to track.
public struct JetBrainsCatalogEntry: Decodable, Sendable, Equatable {
    public let bundleId: String
    public let code: String
    public let caskToken: String
}

/// One app the `SynologyUpdateChecker` knows how to track.
public struct SynologyCatalogEntry: Decodable, Sendable, Equatable {
    public let bundleId: String
    public let identify: String
    public let downloadPage: String

    public init(bundleId: String, identify: String, downloadPage: String) {
        self.bundleId = bundleId
        self.identify = identify
        self.downloadPage = downloadPage
    }

    private enum CodingKeys: String, CodingKey {
        case bundleId, identify, downloadPage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        identify = try container.decode(String.self, forKey: .identify)
        let page = try container.decode(String.self, forKey: .downloadPage)
        // `downloadPage` is handed straight to `NSWorkspace.open` — reject anything that
        // is not an absolute https URL with a host while decoding, so a hostile catalog
        // entry can never reach the open call.
        guard isValidCatalogURL(page) else {
            throw DecodingError.dataCorruptedError(
                forKey: .downloadPage, in: container,
                debugDescription: "downloadPage must be an absolute https URL with a host"
            )
        }
        downloadPage = page
    }
}

/// A Sparkle feed URL hard-mapped for an app that hides `SUFeedURL` at runtime.
public struct SparkleFeedOverrideEntry: Decodable, Sendable, Equatable {
    public let bundleId: String
    public let feedURL: String

    public init(bundleId: String, feedURL: String) {
        self.bundleId = bundleId
        self.feedURL = feedURL
    }

    private enum CodingKeys: String, CodingKey {
        case bundleId, feedURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        let feed = try container.decode(String.self, forKey: .feedURL)
        // Same contract for the Sparkle feed the checker fetches over the network.
        guard isValidCatalogURL(feed) else {
            throw DecodingError.dataCorruptedError(
                forKey: .feedURL, in: container,
                debugDescription: "feedURL must be an absolute https URL with a host"
            )
        }
        feedURL = feed
    }
}

/// Validates a catalog-sourced URL string before it can reach `NSWorkspace.open`
/// (``SynologyCatalogEntry/downloadPage``) or the Sparkle fetch layer
/// (``SparkleFeedOverrideEntry/feedURL``).
///
/// Mirrors the strict contract used for the endpoints overlay in
/// `AppEndpoints.overlaying(_:)`: parse with the strict `URLComponents` parser (macOS 14+
/// `URL(string:)` is too lenient — it accepts spaces and scheme-less strings), then require
/// a non-empty host. The scheme is tightened to https-only here, because every catalog URL
/// is https and these values are opened / fetched verbatim from a file that a PR can change.
func isValidCatalogURL(_ string: String) -> Bool {
    guard let comps = URLComponents(string: string),
          let scheme = comps.scheme?.lowercased(), scheme == "https",
          let host = comps.host, !host.isEmpty
    else { return false }
    return true
}

// MARK: - Catalog

/// The single source of truth for every per-app mapping the update checkers rely on.
///
/// Historically each checker carried its own hard-coded `[String: …]` table, so adding an
/// app meant editing Swift, recompiling and shipping a release. The catalog moves all of
/// those tables into one JSON resource (`app-catalog.json`, bundled with `MacUpdaterCore`)
/// and — optionally — overlays a user-writable copy at
/// `~/Library/Application Support/WegaMacUpdater/app-catalog.json`, so the catalog can be
/// refreshed out-of-band (e.g. fetched remotely) without a new app build. Overlay entries
/// win over bundled ones on a `bundleId` collision and may introduce brand-new apps.
public struct AppCatalog: Decodable, Sendable, Equatable {
    /// The only catalog schema this build knows how to read.
    public static let supportedSchemaVersion = 1

    /// SEC-07 — the format the document declares itself to be in. `schemaVersion` was in the
    /// file from the start and read by nothing: every section decodes `decodeIfPresent`, so a
    /// future v2 catalog whose sections were renamed would have decoded as a *valid, empty*
    /// catalog and silently switched every checker off. It is now a hard gate.
    public let schemaVersion: Int
    /// SEC-07 — monotonic publication counter, inside the signed bytes. Without it an old
    /// catalog with its own old, perfectly valid signature is valid forever, and anyone able
    /// to choose which bytes a client receives can roll it back to a version that predates a
    /// fix. Absent means `0`: catalogs published before this field existed still load, and
    /// the guard starts biting from the first one that carries a generation.
    public let generation: Int
    public let github: [GitHubCatalogEntry]
    public let jetbrains: [JetBrainsCatalogEntry]
    public let synology: [SynologyCatalogEntry]
    public let sparkleFeedOverrides: [SparkleFeedOverrideEntry]

    public init(
        schemaVersion: Int = AppCatalog.supportedSchemaVersion,
        generation: Int = 0,
        github: [GitHubCatalogEntry] = [],
        jetbrains: [JetBrainsCatalogEntry] = [],
        synology: [SynologyCatalogEntry] = [],
        sparkleFeedOverrides: [SparkleFeedOverrideEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.github = github
        self.jetbrains = jetbrains
        self.synology = synology
        self.sparkleFeedOverrides = sparkleFeedOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generation, github, jetbrains, synology, sparkleFeedOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A document that omits the version is one written before the field was enforced;
        // treat it as the schema this build reads. A document that *declares* a version we
        // do not implement is refused outright — decoding it would produce a catalog whose
        // emptiness is indistinguishable from "nothing to configure".
        let declaredSchema = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.supportedSchemaVersion
        guard declaredSchema == Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "unsupported catalog schemaVersion \(declaredSchema); this build reads \(Self.supportedSchemaVersion)"
            )
        }
        schemaVersion = declaredSchema
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        // Every section is optional so an overlay file may carry just one of them.
        github = try container.decodeIfPresent([GitHubCatalogEntry].self, forKey: .github) ?? []
        jetbrains = try container.decodeIfPresent([JetBrainsCatalogEntry].self, forKey: .jetbrains) ?? []
        synology = try container.decodeIfPresent([SynologyCatalogEntry].self, forKey: .synology) ?? []
        sparkleFeedOverrides = try container.decodeIfPresent([SparkleFeedOverrideEntry].self, forKey: .sparkleFeedOverrides) ?? []
    }

    // MARK: Fast lookups (last entry wins, so overlays placed after bundled entries override)

    public var githubRepos: [String: GitHubCatalogEntry] {
        Dictionary(github.map { ($0.bundleId, $0) }, uniquingKeysWith: { _, new in new })
    }

    public var jetbrainsProducts: [String: JetBrainsCatalogEntry] {
        Dictionary(jetbrains.map { ($0.bundleId, $0) }, uniquingKeysWith: { _, new in new })
    }

    public var synologyMappings: [String: SynologyCatalogEntry] {
        Dictionary(synology.map { ($0.bundleId, $0) }, uniquingKeysWith: { _, new in new })
    }

    public var sparkleFeedOverridesByBundleID: [String: String] {
        sparkleFeedOverrides.reduce(into: [:]) { $0[$1.bundleId] = $1.feedURL }
    }

    /// Returns a new catalog with `other`'s entries appended after this one's, so that
    /// `other` (the overlay) wins on `bundleId` collisions in the lookup dictionaries.
    public func overlaying(_ other: AppCatalog) -> AppCatalog {
        AppCatalog(
            schemaVersion: schemaVersion,
            // The merged catalog is as new as the newest document that fed it.
            generation: max(generation, other.generation),
            github: github + other.github,
            jetbrains: jetbrains + other.jetbrains,
            synology: synology + other.synology,
            sparkleFeedOverrides: sparkleFeedOverrides + other.sparkleFeedOverrides
        )
    }
}

// MARK: - Loading

extension AppCatalog {
    /// Process-wide catalog: the bundled baseline with the user overlay applied on top.
    public static let shared: AppCatalog = loadShared()

    /// User-writable overlay location (refreshed out-of-band, e.g. from a remote fetch).
    public static var overlayURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("WegaMacUpdater", isDirectory: true)
            .appendingPathComponent("app-catalog.json", isDirectory: false)
    }

    static func loadShared() -> AppCatalog {
        let bundled = (try? loadBundled()) ?? AppCatalog()
        guard let overlay = loadOverlay() else { return bundled }
        return bundled.overlaying(overlay)
    }

    /// Decodes the JSON shipped inside `MacUpdaterCore`. Throws if the resource is missing
    /// or malformed — a contract the `AppCatalogTests` suite guards.
    public static func loadBundled() throws -> AppCatalog {
        guard let url = Bundle.module.url(forResource: "app-catalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(contentsOf: url)
    }

    static func loadOverlay() -> AppCatalog? {
        let url = overlayURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // SEC-04 / F5(a): this overlay came off the network, from a repository that accepts
        // pull requests. `CatalogRefresher` verifies its signature before writing — but that
        // was the *only* check, leaving the window between "written" and "read on the next
        // launch" unguarded, and asymmetric with `AppEndpoints`. Verify again here against
        // the signature stored beside it; fall back to the bundled catalog when anything is off.
        let signature = try? String(contentsOf: signatureURL(for: url), encoding: .utf8)
        let isValid = signature.map { candidate in
            (try? Data(contentsOf: url)).map { CatalogSignature.verify(data: $0, signatureBase64: candidate) } ?? false
        } ?? false

        guard ConfigOverlayTrust.forCatalog(
            signingConfigured: CatalogSignature.isConfigured,
            signature: signature,
            isValid: isValid
        ).appliesOverlay else {
            WegaLog.error(.app, "app-catalog.json: brak ważnego podpisu — overlay zignorowany, używam katalogu z builda.")
            return nil
        }
        return try? decode(contentsOf: url)
    }

    /// Detached signature stored beside the overlay, mirroring the remote layout
    /// (`app-catalog.json` → `app-catalog.json.sig`).
    static func signatureURL(for overlay: URL) -> URL {
        overlay.appendingPathExtension("sig")
    }

    static func decode(contentsOf url: URL) throws -> AppCatalog {
        try decode(try Data(contentsOf: url))
    }

    /// Decodes a catalog document in either supported shape: a bare catalog, or one wrapped
    /// in a ``CatalogEnvelope`` (SEC-07).
    ///
    /// The envelope is tried **first**, and that order is load-bearing: every catalog section
    /// is optional, so an envelope handed to the bare decoder would decode cleanly as an
    /// *empty* catalog — the exact silent failure this card exists to remove.
    public static func decode(_ data: Data) throws -> AppCatalog {
        guard let envelope = CatalogEnvelope.decode(data) else {
            return try JSONDecoder().decode(AppCatalog.self, from: data)
        }
        guard envelope.isSupportedVersion, let payload = envelope.payload else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return try JSONDecoder().decode(AppCatalog.self, from: payload)
    }
}
