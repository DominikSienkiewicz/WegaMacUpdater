import Foundation
@testable import MacUpdaterCore

final class StubProcessRunner: ProcessRunning {
    let result: ProcessResult
    init(result: ProcessResult) { self.result = result }
    func run(_ request: ProcessRequest) async throws -> ProcessResult { result }
    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Queue-backed `HTTPTransport` fake for checker tests: each call pops the next
/// scripted response; once the queue drains it returns an empty 200 so a retrying
/// client never crashes. Shared by the HTTP-level checker suites (no network).
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
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
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: nil,
                headerFields: stub.headers
            )!
            return (stub.data, response)
        }
    }
}

/// An `HTTPClient` over a one-shot `FakeHTTPTransport`, retries/backoff disabled so
/// failure cases resolve instantly.
enum FakeHTTP {
    static func client(ok body: String, headers: [String: String] = [:]) -> HTTPClient {
        client([.success(.init(data: Data(body.utf8), status: 200, headers: headers))])
    }

    static func client(status: Int, body: String = "") -> HTTPClient {
        client([.success(.init(data: Data(body.utf8), status: status, headers: [:]))])
    }

    static func client(error: Error) -> HTTPClient {
        client([.failure(error)])
    }

    static func client(_ stubs: [Result<FakeHTTPTransport.Stub, Error>]) -> HTTPClient {
        HTTPClient(transport: FakeHTTPTransport(stubs), maxRetries: 0, retryBaseDelay: 0)
    }
}
