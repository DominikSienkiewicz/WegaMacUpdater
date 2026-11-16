import Foundation
import Testing
@testable import MacUpdaterCore

@Suite
struct CaskCatalogStaleCacheTests {
    private final class CountingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let status: Int
        private let body: String

        init(status: Int, body: String) {
            self.status = status
            self.body = body
        }

        var calls: Int { lock.withLock { count } }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.withLock { count += 1 }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private func makeCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "CaskCatalogStaleCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(component: "casks.json", directoryHint: .notDirectory)
    }

    private func makeClient(cacheURL: URL, transport: CountingTransport) -> CaskDatabaseClient {
        CaskDatabaseClient(
            sourceURL: URL(string: "https://example.test/casks.json")!,
            cache: CaskDatabaseCache(fileURL: cacheURL),
            client: HTTPClient(transport: transport, maxRetries: 0, retryBaseDelay: 0)
        )
    }

    @Test
    func staleCacheIsUsedWithoutDownloading() async throws {
        let cacheURL = makeCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try CaskDatabaseCache(fileURL: cacheURL).save([BrewCask(token: "cached", name: ["Cached"])])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 24 * 60 * 60)],
            ofItemAtPath: cacheURL.path
        )
        let transport = CountingTransport(status: 200, body: "[]")

        let casks = try await makeClient(cacheURL: cacheURL, transport: transport).fetchCasksAcceptingStaleCache()

        #expect(casks.map(\.token) == ["cached"])
        #expect(transport.calls == 0)
    }

    @Test
    func missingCacheDownloadsAndSaves() async throws {
        let cacheURL = makeCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let transport = CountingTransport(status: 200, body: #"[{"token":"a","name":["A"]}]"#)

        let casks = try await makeClient(cacheURL: cacheURL, transport: transport).fetchCasksAcceptingStaleCache()

        #expect(casks.map(\.token) == ["a"])
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test
    func downloadFailureThrows() async {
        let cacheURL = makeCacheURL()
        let transport = CountingTransport(status: 500, body: "")

        await #expect(throws: CaskDatabaseError.downloadFailed) {
            _ = try await makeClient(cacheURL: cacheURL, transport: transport).fetchCasksAcceptingStaleCache()
        }
    }
}
