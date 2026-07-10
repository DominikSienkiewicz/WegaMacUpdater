import Testing
import Foundation
@testable import MacUpdaterCore

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Stub { let data: Data; let status: Int; let headers: [String: String] }
    private let lock = NSLock()
    private var queue: [Result<Stub, Error>]
    init(_ responses: [Result<Stub, Error>]) { self.queue = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let next: Result<Stub, Error> = lock.withLock {
            queue.isEmpty ? .success(Stub(data: Data(), status: 200, headers: [:])) : queue.removeFirst()
        }
        switch next {
        case .failure(let error): throw error
        case .success(let stub):
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
            return (stub.data, response)
        }
    }
}

@Suite("CatalogRefresher")
struct CatalogRefresherTests {
    private let source = URL(string: "https://example.com/app-catalog.json")!

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-catalog-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("app-catalog.json")
    }

    private func client(_ stubs: [Result<FakeTransport.Stub, Error>]) -> HTTPClient {
        HTTPClient(transport: FakeTransport(stubs), maxRetries: 0, retryBaseDelay: 0)
    }

    private func ok(_ body: String) -> Result<FakeTransport.Stub, Error> {
        .success(.init(data: Data(body.utf8), status: 200, headers: [:]))
    }

    @Test func writesValidCatalogAndReturnsUpdated() async throws {
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let json = #"{"github":[{"bundleId":"com.x.app","repo":"owner/repo","caskToken":"x"}]}"#

        // Predates signing: this pins "a valid body is decoded and written". Now that a
        // publisher key is compiled in, the catalog is fail-closed and an unsigned body is
        // correctly rejected — so the decode-only path is requested explicitly. The signed
        // path has its own suite (`CatalogRefresherSignaturePersistenceTests`).
        let refresher = CatalogRefresher(
            source: source,
            destination: dest,
            client: client([ok(json)]),
            signatureVerifier: CatalogSignature(publicKeyBase64: CatalogSignature.unconfiguredPlaceholder)
        )
        let outcome = await refresher.refresh()

        #expect(outcome == .updated)
        let written = try AppCatalog.decode(contentsOf: dest)
        #expect(written.github == [GitHubCatalogEntry(bundleId: "com.x.app", repo: "owner/repo", caskToken: "x")])
    }

    @Test func rejectsMalformedBodyAndLeavesDestinationUntouched() async throws {
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        // Seed a known-good overlay that must survive a bad fetch.
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = #"{"jetbrains":[{"bundleId":"com.jb","code":"IIU","caskToken":"intellij-idea"}]}"#
        try Data(good.utf8).write(to: dest)

        let refresher = CatalogRefresher(source: source, destination: dest, client: client([ok("<<not json>>")]))
        let outcome = await refresher.refresh()

        #expect(outcome == .invalid)
        #expect(String(decoding: try Data(contentsOf: dest), as: UTF8.self) == good)
    }

    @Test func returnsFailedOnServerErrorAndWritesNothing() async throws {
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let stub = Result<FakeTransport.Stub, Error>.success(.init(data: Data(), status: 500, headers: [:]))

        let refresher = CatalogRefresher(source: source, destination: dest, client: client([stub]))
        let outcome = await refresher.refresh()

        #expect(outcome == .failed)
        #expect(FileManager.default.fileExists(atPath: dest.path) == false)
    }
}
