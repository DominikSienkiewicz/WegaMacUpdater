import Testing
import Foundation
@testable import MacUpdaterCore

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Stub { let data: Data; let status: Int }
    private let lock = NSLock()
    private var queue: [Stub]
    init(_ stubs: [Stub]) { self.queue = stubs }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let stub = lock.withLock { queue.isEmpty ? Stub(data: Data(), status: 200) : queue.removeFirst() }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: [:])!
        return (stub.data, response)
    }
}

@Suite("ReleaseHistoryFetcher")
struct ReleaseHistoryTests {
    private func release(
        tag: String,
        body: String = "",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> String {
        """
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),
         "body":"\(body)","published_at":"2026-07-20T10:00:00Z",
         "html_url":"https://github.com/owner/repo/releases/tag/\(tag)","assets":[]}
        """
    }

    private func fetcher(_ releases: [String], status: Int = 200, limit: Int = 10) -> ReleaseHistoryFetcher {
        let body = "[\(releases.joined(separator: ","))]"
        let client = HTTPClient(
            transport: FakeTransport([.init(data: Data(body.utf8), status: status)]),
            maxRetries: 0,
            retryBaseDelay: 0
        )
        return ReleaseHistoryFetcher(repo: "owner/repo", client: client)
    }

    @Test func keepsOnlyReleasesNewerThanTheInstalledVersion() async {
        let outcome = await fetcher([
            release(tag: "v1.2.0"),
            release(tag: "v1.1.0"),
            release(tag: "v1.0.0"),
        ]).notesNewerThan("1.1.0")

        guard case .history(let history) = outcome else {
            Issue.record("expected a history, got \(outcome)")
            return
        }
        #expect(history.notes.map(\.version) == ["1.2.0"])
        #expect(history.omitted == 0)
    }

    @Test func ordersNewestFirst() async {
        let outcome = await fetcher([
            release(tag: "v1.1.0"),
            release(tag: "v1.3.0"),
            release(tag: "v1.2.0"),
        ]).notesNewerThan("1.0.0")

        guard case .history(let history) = outcome else {
            Issue.record("expected a history, got \(outcome)")
            return
        }
        #expect(history.notes.map(\.version) == ["1.3.0", "1.2.0", "1.1.0"])
    }

    @Test func dropsDraftsAndPrereleases() async {
        let outcome = await fetcher([
            release(tag: "v1.3.0", draft: true),
            release(tag: "v1.2.0", prerelease: true),
            release(tag: "v1.1.0"),
        ]).notesNewerThan("1.0.0")

        guard case .history(let history) = outcome else {
            Issue.record("expected a history, got \(outcome)")
            return
        }
        #expect(history.notes.map(\.version) == ["1.1.0"])
    }

    /// Release bodies are untrusted vendor input — markup never reaches the window.
    @Test func stripsMarkupFromBodies() async {
        let outcome = await fetcher([
            release(tag: "v1.1.0", body: "<script>alert(1)</script><b>Fixed</b> a crash")
        ]).notesNewerThan("1.0.0")

        guard case .history(let history) = outcome else {
            Issue.record("expected a history, got \(outcome)")
            return
        }
        #expect(history.notes.first?.body.contains("<") == false)
        #expect(history.notes.first?.body.contains("alert") == false)
        #expect(history.notes.first?.body.contains("Fixed") == true)
    }

    @Test func capsTheListAndReportsWhatItLeftOut() async {
        let tags = (1...12).reversed().map { release(tag: "v1.\($0).0") }
        let outcome = await fetcher(tags).notesNewerThan("1.0.0", limit: 10)

        guard case .history(let history) = outcome else {
            Issue.record("expected a history, got \(outcome)")
            return
        }
        #expect(history.notes.count == 10)
        #expect(history.omitted == 2)
    }

    /// "Nothing new to show" and "I could not reach GitHub" are different answers.
    @Test func anEmptyHistoryIsNotAFailure() async {
        let outcome = await fetcher([release(tag: "v1.0.0")]).notesNewerThan("1.0.0")

        guard case .history(let history) = outcome else {
            Issue.record("expected a history, got \(outcome)")
            return
        }
        #expect(history.notes.isEmpty)
    }

    @Test func reportsUnavailableOnATransportFailure() async {
        let outcome = await fetcher([], status: 503).notesNewerThan("1.0.0")
        #expect(outcome == .unavailable)
    }
}
