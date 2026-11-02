import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("HTTP diagnostic traces")
struct HTTPDiagnosticTraceTests {
    @Test func retryRecordsAttemptsAndResponseWithoutRequestSecrets() async throws {
        let fixture = try TraceFixture()
        defer { fixture.remove() }
        let transport = TraceTransport([
            .response(503, [:], "unavailable"),
            .response(200, [:], "response-secret"),
        ])
        let client = HTTPClient(transport: transport, maxRetries: 1, retryBaseDelay: 0)
        let request = HTTPRequest(
            url: URL(string: "https://login:password@example.test/releases/latest?token=query-secret#fragment-secret")!,
            method: "POST", headers: ["Authorization": "Bearer header-secret"], body: Data("body-secret".utf8)
        )

        let response = try await UpdateDiagnostics.$current.withValue(fixture.run) {
            try await client.send(request)
        }

        #expect(response.statusCode == 200)
        #expect(transport.requestCount == 2)
        let events = fixture.events
        #expect(events.filter { $0.event == "http.attempt.started" }.map { $0.fields["attempt"] } == ["1", "2"])
        #expect(events.filter { $0.event == "http.response" }.map { $0.fields["status"] } == ["503", "200"])
        #expect(events.contains { $0.event == "http.retry" && $0.fields["reason"] == "http_status" })
        #expect(events.contains { $0.event == "http.request" && $0.fields["method"] == "POST" && $0.fields["host"] == "example.test" })
        #expect(events.filter { $0.event == "http.response" }.allSatisfy { $0.fields["elapsedMilliseconds"] != nil })
        let recorded = events.map { String(describing: $0.fields) }.joined()
        for secret in ["login", "password", "query-secret", "fragment-secret", "header-secret", "body-secret", "response-secret"] {
            #expect(!recorded.contains(secret))
        }
    }

    @Test func cacheHitRetainsRaw304AndEffective200() async throws {
        let fixture = try TraceFixture()
        defer { fixture.remove() }
        let transport = TraceTransport([
            .response(200, ["ETag": "private-etag"], "cached-body"),
            .response(304, [:], ""),
        ])
        let client = HTTPClient(transport: transport, maxRetries: 0)
        let url = URL(string: "https://example.test/latest")!

        let response = try await UpdateDiagnostics.$current.withValue(fixture.run) {
            _ = try await client.get(url, enableETag: true)
            return try await client.get(url, enableETag: true)
        }

        #expect(response.notModified)
        #expect(String(decoding: response.data, as: UTF8.self) == "cached-body")
        #expect(fixture.events.contains { $0.event == "http.response" && $0.fields["status"] == "304" })
        #expect(fixture.events.contains { $0.event == "http.completed" && $0.fields["status"] == "200" && $0.fields["cache"] == "hit" })
        #expect(!fixture.events.map { String(describing: $0.fields) }.joined().contains("private-etag"))
    }

    @Test func cancellationIsRecordedWithoutRetryOrErrorDescription() async throws {
        let fixture = try TraceFixture()
        defer { fixture.remove() }
        let transport = TraceTransport([.failure(URLError(.cancelled, userInfo: [NSLocalizedDescriptionKey: "private-error"]))])
        let client = HTTPClient(transport: transport, maxRetries: 2, retryBaseDelay: 0)

        do {
            _ = try await UpdateDiagnostics.$current.withValue(fixture.run) {
                try await client.get(URL(string: "https://example.test/latest")!)
            }
            Issue.record("A cancelled transport must still throw")
        } catch {
            #expect((error as? URLError)?.code == .cancelled)
        }

        #expect(transport.requestCount == 1)
        #expect(fixture.events.contains { $0.event == "http.transport.failed" && $0.fields["cancelled"] == "true" })
        #expect(!fixture.events.contains { $0.event == "http.retry" })
        #expect(!fixture.events.map { String(describing: $0.fields) }.joined().contains("private-error"))
    }

    @Test func requestOutsideRunDoesNotAppendToAnUnrelatedTrace() async throws {
        let fixture = try TraceFixture()
        defer { fixture.remove() }
        let initialCount = fixture.events.count
        let client = HTTPClient(transport: TraceTransport([.response(200, [:], "ok")]), maxRetries: 0)

        _ = try await UpdateDiagnostics.$current.withValue(nil) {
            try await client.get(URL(string: "https://example.test/latest")!)
        }

        #expect(fixture.events.count == initialCount)
    }

    @Test func transientTransportFailureKeepsRetryReasonAndRecoveredResult() async throws {
        let fixture = try TraceFixture()
        defer { fixture.remove() }
        let transport = TraceTransport([.failure(URLError(.timedOut)), .response(200, [:], "ok")])
        let client = HTTPClient(transport: transport, maxRetries: 1, retryBaseDelay: 0)

        let response = try await UpdateDiagnostics.$current.withValue(fixture.run) {
            try await client.get(URL(string: "https://example.test/latest")!)
        }

        #expect(response.statusCode == 200)
        #expect(transport.requestCount == 2)
        #expect(fixture.events.contains { $0.event == "http.transport.failed" && $0.fields["errorCode"] == "-1001" })
        #expect(fixture.events.contains { $0.event == "http.retry" && $0.fields["reason"] == "transport_error" })
    }

    @Test func serverWaitBeyondLimitIsExplainedWithoutAnExtraAttempt() async throws {
        let fixture = try TraceFixture()
        defer { fixture.remove() }
        let transport = TraceTransport([.response(429, ["Retry-After": "3600"], "")])
        let client = HTTPClient(transport: transport, maxRetries: 1, retryBaseDelay: 0)

        let response = try await UpdateDiagnostics.$current.withValue(fixture.run) {
            try await client.get(URL(string: "https://example.test/latest")!)
        }

        #expect(response.statusCode == 429)
        #expect(transport.requestCount == 1)
        #expect(fixture.events.contains { $0.event == "http.retry.skipped" && $0.fields["reason"] == "server_wait_exceeds_limit" })
    }
}

private struct TraceFixture {
    let directory: URL
    let store: DiagnosticTraceStore
    let run: DiagnosticRun

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = DiagnosticTraceStore(directory: directory)
        run = DiagnosticRun(trigger: "test", subjects: ["example"], store: store)
    }

    var events: [DiagnosticEvent] { store.events(runID: run.id) }

    func remove() {
        run.finish()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class TraceTransport: HTTPTransport, @unchecked Sendable {
    enum Result {
        case response(Int, [String: String], String)
        case failure(URLError)
    }

    private let lock = NSLock()
    private var results: [Result]
    private var calls = 0

    init(_ results: [Result]) { self.results = results }

    var requestCount: Int { lock.withLock { calls } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result = lock.withLock {
            calls += 1
            return results.removeFirst()
        }
        switch result {
        case .failure(let error): throw error
        case .response(let status, let headers, let body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }
}
