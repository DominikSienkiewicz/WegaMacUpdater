import Foundation

public struct AdobeCatalogCache: Sendable {
    public var fileURL: URL
    public var ttl: TimeInterval

    public init(fileURL: URL, ttl: TimeInterval = 24 * 60 * 60) {
        self.fileURL = fileURL
        self.ttl = ttl
    }

    public func loadIfFresh(now: Date = Date()) throws -> AdobeProductCatalog? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let modifiedAt = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modifiedAt) <= ttl else { return nil }
        return try JSONDecoder().decode(AdobeProductCatalog.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ catalog: AdobeProductCatalog) throws {
        let data = try JSONEncoder().encode(catalog)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// Downloads Adobe's Creative Cloud product feed once per day and caches the reduction of it
/// Wega actually uses.
///
/// The feed is one document covering every product, not a per-app endpoint, so it is fetched
/// as a scan prologue — the same shape as ``CaskDatabaseClient`` — rather than through the
/// per-app ``VendorUpdateChecker`` driver: that would re-download and re-parse the whole
/// catalog once per installed Adobe app, and the feed serves no `ETag` to make the repeat
/// requests cheap.
public final class AdobeCatalogClient: @unchecked Sendable {
    /// Adobe rejects the request outright without both headers. Neither is a credential:
    /// the endpoint serves the same public catalog to anyone, and Creative Cloud's own
    /// installer sends exactly these to identify the caller.
    public static let requestHeaders = [
        "X-Api-Key": "CCHomeWeb1",
        "X-Adobe-App-Id": "accc-hdcore-desktop",
    ]

    private let sourceURL: URL
    private let cache: AdobeCatalogCache?
    private let client: HTTPClient

    public init(
        sourceURL: URL = AppEndpoints.shared.adobeProductCatalogURL,
        cache: AdobeCatalogCache? = nil,
        client: HTTPClient = .shared
    ) {
        self.sourceURL = sourceURL
        self.cache = cache
        self.client = client
    }

    public func fetchCatalog() async throws -> AdobeProductCatalog {
        if let cached = try cache?.loadIfFresh() { return cached }

        let response = try await client.get(sourceURL, headers: Self.requestHeaders)
        guard response.isOK else { throw AdobeCatalogError.downloadFailed }
        guard let catalog = AdobeProductCatalog.parse(xml: response.data) else {
            throw AdobeCatalogError.malformedCatalog
        }
        try? cache?.save(catalog)
        return catalog
    }
}

public extension AdobeCatalogClient {
    /// The scan prologue: a client backed by the shared on-disk catalog cache, mirroring
    /// ``CaskDatabaseClient/caskCatalog(cacheURL:)``.
    static func productCatalog(
        cacheURL: URL = AdobeCatalogClient.defaultCacheURL
    ) -> AdobeCatalogClient {
        AdobeCatalogClient(cache: AdobeCatalogCache(fileURL: cacheURL))
    }

    /// Caches, not Application Support: losing this file costs one extra download.
    static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/adobe-products.json")
    }
}

public enum AdobeCatalogError: Error, Equatable, LocalizedError {
    case downloadFailed
    case malformedCatalog

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:   return "Failed to download the Adobe product catalog."
        case .malformedCatalog: return "The Adobe product catalog could not be parsed."
        }
    }
}
