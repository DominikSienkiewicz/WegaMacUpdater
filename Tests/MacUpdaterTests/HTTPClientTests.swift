import XCTest
@testable import MacUpdaterCore

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Stub { let data: Data; let status: Int; let headers: [String: String] }

    private let lock = NSLock()
    private var queue: [Result<Stub, Error>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<Stub, Error>]) { self.queue = responses }

    var requestCount: Int { lock.withLock { requests.count } }
    func request(at index: Int) -> URLRequest { lock.withLock { requests[index] } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let next: Result<Stub, Error> = lock.withLock {
            requests.append(request)
            return queue.isEmpty ? .success(Stub(data: Data(), status: 200, headers: [:])) : queue.removeFirst()
        }
        switch next {
        case .failure(let error):
            throw error
        case .success(let stub):
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
            return (stub.data, response)
        }
    }
}

private func ok(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Result<FakeTransport.Stub, Error> {
    .success(FakeTransport.Stub(data: Data(body.utf8), status: status, headers: headers))
}

final class HTTPClientTests: XCTestCase {
    private let url = URL(string: "https://example.com/api")!

    // MARK: User-Agent

    func testDefaultUserAgentIsInjected() async throws {
        let transport = FakeTransport([ok("hi")])
        let client = HTTPClient(transport: transport, userAgent: "Test/9.9", maxRetries: 0, retryBaseDelay: 0)
        _ = try await client.get(url)
        XCTAssertEqual(transport.request(at: 0).value(forHTTPHeaderField: "User-Agent"), "Test/9.9")
    }

    func testCallerProvidedUserAgentIsNotOverridden() async throws {
        let transport = FakeTransport([ok("hi")])
        let client = HTTPClient(transport: transport, userAgent: "Test/9.9", maxRetries: 0, retryBaseDelay: 0)
        _ = try await client.get(url, headers: ["User-Agent": "Custom/1.0"])
        XCTAssertEqual(transport.request(at: 0).value(forHTTPHeaderField: "User-Agent"), "Custom/1.0")
    }

    // MARK: ETag conditional caching

    func testETagIsStoredAndConditionalRequestServesCachedBodyOn304() async throws {
        let transport = FakeTransport([
            ok("payload-v1", headers: ["ETag": "\"abc123\""]),
            .success(FakeTransport.Stub(data: Data(), status: 304, headers: [:])),
        ])
        let client = HTTPClient(transport: transport, maxRetries: 0, retryBaseDelay: 0)

        let first = try await client.get(url, enableETag: true)
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(String(decoding: first.data, as: UTF8.self), "payload-v1")
        XCTAssertFalse(first.notModified)

        let second = try await client.get(url, enableETag: true)
        XCTAssertEqual(second.statusCode, 200)
        XCTAssertEqual(String(decoding: second.data, as: UTF8.self), "payload-v1", "304 must replay the cached body")
        XCTAssertTrue(second.notModified)

        XCTAssertEqual(transport.request(at: 1).value(forHTTPHeaderField: "If-None-Match"), "\"abc123\"")
    }

    func testETagNotSentWhenDisabled() async throws {
        let transport = FakeTransport([
            ok("v1", headers: ["ETag": "\"abc\""]),
            ok("v2", headers: ["ETag": "\"def\""]),
        ])
        let client = HTTPClient(transport: transport, maxRetries: 0, retryBaseDelay: 0)
        _ = try await client.get(url)           // enableETag defaults to false
        _ = try await client.get(url)
        XCTAssertNil(transport.request(at: 1).value(forHTTPHeaderField: "If-None-Match"))
    }

    // MARK: Retry

    func testRetriesOnServerErrorThenSucceeds() async throws {
        let transport = FakeTransport([ok("", status: 503), ok("recovered")])
        let client = HTTPClient(transport: transport, maxRetries: 2, retryBaseDelay: 0)
        let response = try await client.get(url)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "recovered")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testRetriesOnThrownNetworkErrorThenSucceeds() async throws {
        let transport = FakeTransport([.failure(URLError(.timedOut)), ok("recovered")])
        let client = HTTPClient(transport: transport, maxRetries: 2, retryBaseDelay: 0)
        let response = try await client.get(url)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testDoesNotRetryOnClientError() async throws {
        let transport = FakeTransport([ok("nope", status: 404)])
        let client = HTTPClient(transport: transport, maxRetries: 2, retryBaseDelay: 0)
        let response = try await client.get(url)
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(transport.requestCount, 1, "4xx is definitive — no retry")
    }

    func testGivesUpAfterMaxRetries() async throws {
        let transport = FakeTransport([ok("", status: 500), ok("", status: 500), ok("", status: 500)])
        let client = HTTPClient(transport: transport, maxRetries: 2, retryBaseDelay: 0)
        let response = try await client.get(url)
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertEqual(transport.requestCount, 3, "1 initial + 2 retries")
    }

    // MARK: POST

    func testPostSendsBodyAndContentType() async throws {
        let transport = FakeTransport([ok("done")])
        let client = HTTPClient(transport: transport, maxRetries: 0, retryBaseDelay: 0)
        _ = try await client.post(url, body: Data("<xml/>".utf8), contentType: "application/xml")
        let sent = transport.request(at: 0)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.httpBody, Data("<xml/>".utf8))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/xml")
    }
}
