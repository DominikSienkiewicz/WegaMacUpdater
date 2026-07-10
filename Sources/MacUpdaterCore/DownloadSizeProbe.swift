import Foundation

/// Outcome of a download-size probe (F2). Three first-class states: `brew info`
/// carries **no** size field, so the plan-preview panel must render an honest
/// "nieznany" rather than the `DownloadGate` placeholder of `200 MB + 1`.
///
/// `unknown` is **not** an error — a `HEAD` that omits `Content-Length` is routine
/// behind a CDN (chunked transfer / streamed origin). Only a rejected request or a
/// broken network is a `failed`.
public enum DownloadSizeProbeResult: Equatable, Sendable {
    /// Server reported an exact byte count via `Content-Length`.
    case known(bytes: Int64)
    /// Request succeeded but no usable `Content-Length` was present.
    case unknown
    /// The size could not be measured (non-2xx status, transport error, or a
    /// URL rejected before any request was made).
    case failed(reason: String)
}

/// Measures a cask download's size with a single HTTP `HEAD`, reading
/// `Content-Length`. Sits behind the existing `HTTPTransport` seam (URLSession in
/// production, a fake in tests) so it never touches the real network under test.
///
/// SEC-09: only `https` URLs are probed — anything else is rejected up front,
/// without a request.
public struct DownloadSizeProbe: Sendable {
    private let transport: HTTPTransport
    private let userAgent: String

    public init(
        transport: HTTPTransport = HTTPClient.makeDefaultSession(),
        userAgent: String = HTTPClient.defaultUserAgent
    ) {
        self.transport = transport
        self.userAgent = userAgent
    }

    /// Probe `urlString` for its download size. Never throws — every failure mode
    /// is folded into `DownloadSizeProbeResult`.
    public func probe(urlString: String) async -> DownloadSizeProbeResult {
        guard let url = URL(string: urlString), let scheme = url.scheme else {
            return .failed(reason: "niepoprawny URL")
        }
        guard scheme.lowercased() == "https" else {
            return .failed(reason: "URL nie jest https (SEC-09)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(reason: "brak odpowiedzi HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(reason: "HTTP \(http.statusCode)")
            }
            if let raw = http.value(forHTTPHeaderField: "Content-Length"),
               let bytes = Int64(raw), bytes >= 0 {
                return .known(bytes: bytes)
            }
            return .unknown
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}
