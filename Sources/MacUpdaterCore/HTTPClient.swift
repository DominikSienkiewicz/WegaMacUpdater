import Foundation

// MARK: - Request / Response

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// When true, the client sends `If-None-Match` from its ETag store and, on a
    /// `304 Not Modified`, returns the cached body. For GitHub this also means the
    /// request does **not** count against the 60-req/h unauthenticated rate limit.
    public var enableETag: Bool

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        enableETag: Bool = false
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.enableETag = enableETag
    }
}

public struct HTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    /// True when the body was served from the ETag cache after a 304.
    public var notModified: Bool

    public init(data: Data, statusCode: Int, notModified: Bool = false) {
        self.data = data
        self.statusCode = statusCode
        self.notModified = notModified
    }

    public var isOK: Bool { (200..<300).contains(statusCode) }
}

// MARK: - Transport seam (URLSession in production, a fake in tests)

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

// MARK: - ETag store

/// Process-lifetime store of `(ETag, body)` per URL. In-memory by design: the wins
/// (conditional GETs across repeated "Sprawdź" passes in one session) don't need to
/// survive relaunches, and keeping it off disk avoids stale-cache headaches.
final class ETagStore: @unchecked Sendable {
    struct Entry: Sendable { let etag: String; let data: Data }

    private let lock = NSLock()
    private var storage: [String: Entry] = [:]

    func entry(for url: URL) -> Entry? {
        lock.withLock { storage[url.absoluteString] }
    }

    func store(_ entry: Entry, for url: URL) {
        lock.withLock { storage[url.absoluteString] = entry }
    }
}

// MARK: - HTTPClient

/// One shared HTTP client for every update checker: uniform timeouts, a single
/// `User-Agent`, transient-failure retry with exponential backoff, and ETag-based
/// conditional requests. Replaces nine ad-hoc `URLSession` call sites.
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    private let transport: HTTPTransport
    private let userAgent: String
    private let maxRetries: Int
    private let retryBaseDelay: TimeInterval
    private let etagStore = ETagStore()

    public init(
        transport: HTTPTransport = HTTPClient.makeDefaultSession(),
        userAgent: String = HTTPClient.defaultUserAgent,
        maxRetries: Int = 2,
        retryBaseDelay: TimeInterval = 0.4
    ) {
        self.transport = transport
        self.userAgent = userAgent
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
    }

    public static var defaultUserAgent: String { "WegaMacUpdater/\(AppMetadata.version)" }

    public static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // We handle revalidation ourselves via ETag, so bypass URLCache.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    // MARK: Convenience

    public func get(_ url: URL, headers: [String: String] = [:], enableETag: Bool = false) async throws -> HTTPResponse {
        try await send(HTTPRequest(url: url, method: "GET", headers: headers, enableETag: enableETag))
    }

    public func post(_ url: URL, body: Data, contentType: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        var merged = headers
        merged["Content-Type"] = contentType
        return try await send(HTTPRequest(url: url, method: "POST", headers: merged, body: body))
    }

    // MARK: Core

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if request.headers["User-Agent"] == nil {
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let cached = request.enableETag ? etagStore.entry(for: request.url) : nil
        if let cached {
            urlRequest.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await performWithRetry(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            return HTTPResponse(data: data, statusCode: -1)
        }

        // 304: serve the stored body and report it as OK so callers' `== 200`
        // checks keep working transparently.
        if http.statusCode == 304, let cached {
            return HTTPResponse(data: cached.data, statusCode: 200, notModified: true)
        }

        if request.enableETag, (200..<300).contains(http.statusCode),
           let etag = http.value(forHTTPHeaderField: "ETag") {
            etagStore.store(ETagStore.Entry(etag: etag, data: data), for: request.url)
        }

        return HTTPResponse(data: data, statusCode: http.statusCode)
    }

    // MARK: Retry

    private func performWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        let target = request.url?.absoluteString ?? "<no url>"
        while true {
            do {
                let (data, response) = try await transport.data(for: request)
                if let http = response as? HTTPURLResponse,
                   shouldRetry(http),
                   attempt < maxRetries {
                    attempt += 1
                    let delay = retryDelay(http: http, attempt: attempt)
                    AppLogger.network.notice(
                        "HTTP \(http.statusCode, privacy: .public) from \(target, privacy: .public) — retry \(attempt, privacy: .public)/\(self.maxRetries, privacy: .public) za \(delay, privacy: .public)s"
                    )
                    try await sleepFor(delay)
                    continue
                }
                return (data, response)
            } catch {
                if attempt < maxRetries, isRetryable(error) {
                    attempt += 1
                    AppLogger.network.notice(
                        "transport error for \(target, privacy: .public) — retry \(attempt, privacy: .public)/\(self.maxRetries, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    try await sleepFor(retryDelay(http: nil, attempt: attempt))
                    continue
                }
                // A user-driven cancellation isn't a failure worth flagging — only log
                // genuine give-ups so Console shows real connectivity/endpoint problems.
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    AppLogger.network.error(
                        "HTTP request to \(target, privacy: .public) failed (\(attempt, privacy: .public) retries used): \(error.localizedDescription, privacy: .public)"
                    )
                }
                throw error
            }
        }
    }

    /// 429 i 5xx są przejściowe. Dodatkowo (SEC-05): GitHub primary rate-limit
    /// potrafi wrócić `403` z `X-RateLimit-Remaining: 0` — to też jest rate-limit,
    /// nie definitywny błąd, więc retry'ujemy (z poszanowaniem Retry-After/Reset).
    private func shouldRetry(_ http: HTTPURLResponse) -> Bool {
        let status = http.statusCode
        if status == 429 || (500..<600).contains(status) { return true }
        if status == 403, http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" { return true }
        return false
    }

    private func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        return true
    }

    /// Honoruj sygnały serwera najpierw: `Retry-After` (sekundy), potem
    /// `X-RateLimit-Reset` (epoch). W przeciwnym razie exponential backoff z
    /// pełnym jitterem. Wszystko zacapowane do 60 s, by uniknąć absurdalnych czekań.
    private func retryDelay(http: HTTPURLResponse?, attempt: Int) -> TimeInterval {
        let cap: TimeInterval = 60
        if let http {
            if let raw = http.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(raw) {
                return min(max(0, seconds), cap)
            }
            if let raw = http.value(forHTTPHeaderField: "X-RateLimit-Reset"), let reset = TimeInterval(raw) {
                let wait = reset - Date().timeIntervalSince1970
                if wait > 0 { return min(wait, cap) }
            }
        }
        guard retryBaseDelay > 0 else { return 0 }   // utrzymuje testy (retryBaseDelay: 0) natychmiastowe
        let base = retryBaseDelay * pow(2.0, Double(max(0, attempt - 1)))
        return min(base + Double.random(in: 0...base), cap)   // full jitter
    }

    private func sleepFor(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
