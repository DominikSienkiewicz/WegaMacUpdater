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

public enum CaskDatabaseError: Error, Equatable, LocalizedError {
    case downloadFailed

    public var errorDescription: String? {
        "Failed to download the Homebrew cask database."
    }
}
