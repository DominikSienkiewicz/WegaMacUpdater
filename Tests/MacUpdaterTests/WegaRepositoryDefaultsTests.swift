import Foundation
import Testing
@testable import MacUpdaterCore

/// Records the URL of every request and answers 404, so a test sees where a query goes
/// without depending on what the release API returns.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []

    var requestedURLs: [String] { lock.withLock { urls } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        lock.withLock { urls.append(url.absoluteString) }
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!
        return (Data(), response)
    }
}

/// The repository spent 2026-11-13 and 2026-11-14 in an organization and then moved back to
/// the personal account. The self-update check and the release notes must ask the account
/// that owns the repository directly instead of relying on GitHub's redirect, which
/// disappears if a former name is ever reused.
@Suite("Wega's own GitHub repository")
struct WegaRepositoryDefaultsTests {
    private static let repository = "DominikSienkiewicz/WegaMacUpdater"

    @Test func selfUpdateCheckAsksTheOwningRepository() async {
        let transport = RecordingTransport()
        let client = HTTPClient(transport: transport, maxRetries: 0, retryBaseDelay: 0)

        _ = await WegaSelfUpdateChecker(currentVersion: "0.1.0", client: client).check()

        #expect(transport.requestedURLs == ["https://api.github.com/repos/\(Self.repository)/releases/latest"])
    }

    @Test func releaseHistoryAsksTheOwningRepository() async {
        let transport = RecordingTransport()
        let client = HTTPClient(transport: transport, maxRetries: 0, retryBaseDelay: 0)

        _ = await ReleaseHistoryFetcher(client: client).notesNewerThan("0.1.0")

        #expect(transport.requestedURLs == ["https://api.github.com/repos/\(Self.repository)/releases?per_page=100"])
    }
}
