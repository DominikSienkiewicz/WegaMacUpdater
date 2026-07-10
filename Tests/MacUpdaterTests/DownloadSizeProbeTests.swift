import XCTest
@testable import MacUpdaterCore

/// Recording `HTTPTransport` fake — zero real network. Counts invocations so
/// tests can assert the probe short-circuits (HTTPS-only / invalid URL) *before*
/// touching the transport.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stub: Result<(Int, [String: String]), Error>
    private(set) var requests: [URLRequest] = []

    init(status: Int, headers: [String: String]) {
        self.stub = .success((status, headers))
    }

    init(error: Error) {
        self.stub = .failure(error)
    }

    var callCount: Int { lock.withLock { requests.count } }
    func request(at index: Int) -> URLRequest { lock.withLock { requests[index] } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { requests.append(request) }
        switch stub {
        case .failure(let error):
            throw error
        case .success(let (status, headers)):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            return (Data(), response)
        }
    }
}

final class DownloadSizeProbeTests: XCTestCase {
    private let httpsURL = "https://dl.example.com/app.dmg"

    // MARK: Known size

    func testContentLengthPresentYieldsKnownSize() async {
        let transport = RecordingTransport(status: 200, headers: ["Content-Length": "20971520"])
        let probe = DownloadSizeProbe(transport: transport)

        let result = await probe.probe(urlString: httpsURL)

        XCTAssertEqual(result, .known(bytes: 20_971_520))
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(transport.request(at: 0).httpMethod, "HEAD")
    }

    // MARK: Unknown (no Content-Length — common behind a CDN)

    func testMissingContentLengthYieldsUnknown() async {
        let transport = RecordingTransport(status: 200, headers: [:])
        let probe = DownloadSizeProbe(transport: transport)

        let result = await probe.probe(urlString: httpsURL)

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(transport.callCount, 1)
    }

    // MARK: Error — non-2xx status

    func testClientErrorStatusYieldsFailure() async {
        let transport = RecordingTransport(status: 404, headers: ["Content-Length": "10"])
        let probe = DownloadSizeProbe(transport: transport)

        let result = await probe.probe(urlString: httpsURL)

        guard case .failed = result else {
            return XCTFail("expected .failed for 404, got \(result)")
        }
    }

    func testServerErrorStatusYieldsFailure() async {
        let transport = RecordingTransport(status: 503, headers: [:])
        let probe = DownloadSizeProbe(transport: transport)

        let result = await probe.probe(urlString: httpsURL)

        guard case .failed = result else {
            return XCTFail("expected .failed for 503, got \(result)")
        }
    }

    // MARK: Error — thrown transport (network) error

    func testThrownNetworkErrorYieldsFailure() async {
        let transport = RecordingTransport(error: URLError(.timedOut))
        let probe = DownloadSizeProbe(transport: transport)

        let result = await probe.probe(urlString: httpsURL)

        guard case .failed = result else {
            return XCTFail("expected .failed for thrown error, got \(result)")
        }
    }

    // MARK: SEC-09 — HTTPS only, rejected without touching the network

    func testNonHTTPSURLIsRejectedWithoutCallingTransport() async {
        let transport = RecordingTransport(status: 200, headers: ["Content-Length": "10"])
        let probe = DownloadSizeProbe(transport: transport)

        let result = await probe.probe(urlString: "http://dl.example.com/app.dmg")

        guard case .failed = result else {
            return XCTFail("expected .failed for http:// URL, got \(result)")
        }
        XCTAssertEqual(transport.callCount, 0, "non-https must not reach the transport")
    }

    // MARK: Invalid URL — rejected without touching the network

    func testInvalidURLIsRejectedWithoutCallingTransport() async {
        let transport = RecordingTransport(status: 200, headers: ["Content-Length": "10"])
        let probe = DownloadSizeProbe(transport: transport)

        let result = await probe.probe(urlString: "not a valid url")

        guard case .failed = result else {
            return XCTFail("expected .failed for invalid URL, got \(result)")
        }
        XCTAssertEqual(transport.callCount, 0, "an unparseable URL must not reach the transport")
    }
}
