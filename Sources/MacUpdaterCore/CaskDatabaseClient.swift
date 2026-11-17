import Foundation

public struct CaskDatabaseCache {
    public var fileURL: URL
    public var ttl: TimeInterval

    public init(fileURL: URL, ttl: TimeInterval = 24 * 60 * 60) {
        self.fileURL = fileURL
        self.ttl = ttl
    }

    public func loadIfFresh(now: Date = Date()) throws -> [BrewCask]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let modifiedAt = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modifiedAt) <= ttl else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([BrewCask].self, from: data)
    }

    /// Reads the cache regardless of its age, for callers that prefer slightly old data to a
    /// network wait.
    public func loadAnyAge() throws -> [BrewCask]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([BrewCask].self, from: data)
    }

    public func save(_ casks: [BrewCask]) throws {
        let data = try JSONEncoder().encode(casks)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }
}

public final class CaskDatabaseClient: @unchecked Sendable {
    public static let defaultURL = AppEndpoints.shared.caskDatabaseURL

    private let sourceURL: URL
    private let cache: CaskDatabaseCache?
    private let client: HTTPClient

    public init(
        sourceURL: URL = CaskDatabaseClient.defaultURL,
        cache: CaskDatabaseCache? = nil,
        client: HTTPClient = .shared
    ) {
        self.sourceURL = sourceURL
        self.cache = cache
        self.client = client
    }

    public func fetchCasks() async throws -> [BrewCask] {
        if let cached = try cache?.loadIfFresh() {
            return cached
        }
        return try await downloadCasks()
    }

    /// Uninstall needs the cask's zap paths, not the newest version data, so a cache of any
    /// age is good enough and the network is only used when there is none, or when the cache no
    /// longer decodes: the download then replaces it instead of every sheet failing on it.
    public func fetchCasksAcceptingStaleCache() async throws -> [BrewCask] {
        if let cached = try loadAnyAgeUnlessCorrupt() {
            return cached
        }
        return try await downloadCasks()
    }

    private func loadAnyAgeUnlessCorrupt() throws -> [BrewCask]? {
        do {
            return try cache?.loadAnyAge()
        } catch is DecodingError {
            return nil
        }
    }

    private func downloadCasks() async throws -> [BrewCask] {
        // Disk freshness is handled by `cache`; the client provides uniform
        // timeout / User-Agent / retry.
        let response = try await client.get(sourceURL)
        guard response.isOK else {
            throw CaskDatabaseError.downloadFailed
        }

        let casks = try JSONDecoder().decode([BrewCask].self, from: response.data)
        try cache?.save(casks)
        return casks
    }
}

public extension CaskDatabaseClient {
    /// The single app-scan prologue: a catalog client backed by the shared on-disk cask
    /// cache at `AppScanDirectories.caskDatabaseCacheURL`.
    ///
    /// Every scan that matches installed apps against Homebrew — the Updates window's manual
    /// checks, the Inventory window, and the Migration window — acquires the catalog through
    /// here instead of rebuilding the `Library/Caches/…/casks.json` path and wrapping it in a
    /// `CaskDatabaseCache` by hand. `cacheURL` is injectable so a test can point the prologue
    /// at a temporary cache; production always uses the default.
    static func caskCatalog(
        cacheURL: URL = AppScanDirectories.caskDatabaseCacheURL
    ) -> CaskDatabaseClient {
        CaskDatabaseClient(cache: CaskDatabaseCache(fileURL: cacheURL))
    }

    /// The catalog the Uninstall sheet reads: the same shared cache, but with no download
    /// retries, so the shared session's 15 s request / 30 s resource timeout is the longest
    /// the sheet waits when the cache is missing.
    static func uninstallCatalog(
        cacheURL: URL = AppScanDirectories.caskDatabaseCacheURL
    ) -> CaskDatabaseClient {
        CaskDatabaseClient(
            cache: CaskDatabaseCache(fileURL: cacheURL),
            client: HTTPClient(maxRetries: 0)
        )
    }
}

public enum CaskDatabaseError: Error, Equatable, LocalizedError {
    case downloadFailed

    public var errorDescription: String? {
        "Failed to download the Homebrew cask database."
    }
}
