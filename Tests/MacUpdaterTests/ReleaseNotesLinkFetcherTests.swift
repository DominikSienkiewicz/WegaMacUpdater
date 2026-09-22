import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("ReleaseNotesLinkFetcher")
struct ReleaseNotesLinkFetcherTests {

    /// `FakeHTTP` is the suite-wide double in `Tests/MacUpdaterTests/TestDoubles.swift` —
    /// no bespoke transport needed here.
    private func fetcher(
        body: String,
        status: Int = 200,
        maxBytes: Int = 256 * 1024,
        maxCharacters: Int = 20_000
    ) -> ReleaseNotesLinkFetcher {
        ReleaseNotesLinkFetcher(
            client: status == 200 ? FakeHTTP.client(ok: body) : FakeHTTP.client(status: status, body: body),
            maxBytes: maxBytes,
            maxCharacters: maxCharacters
        )
    }

    @Test func refusesPlainHttpWithoutAskingTheNetwork() async {
        let outcome = await fetcher(body: "<p>Notes</p>")
            .text(at: URL(string: "http://example.com/notes")!)

        #expect(outcome == .unavailable)
    }

    @Test func stripsMarkupFromTheFetchedPage() async {
        let outcome = await fetcher(body: "<html><body><h1>2.0</h1><p>Fixed a crash</p></body></html>")
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .notes(text: "2.0\nFixed a crash", truncated: false))
    }

    @Test func aNonOkStatusIsUnavailableNotEmptyNotes() async {
        let outcome = await fetcher(body: "", status: 503)
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .unavailable)
    }

    @Test func refusesAPageOverTheByteCap() async {
        let outcome = await fetcher(body: String(repeating: "a", count: 50), maxBytes: 10)
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .unavailable)
    }

    @Test func truncatesOverTheCharacterCapAndSaysSo() async {
        let outcome = await fetcher(body: String(repeating: "a", count: 50), maxCharacters: 10)
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .notes(text: String(repeating: "a", count: 10), truncated: true))
    }

    @Test func aPageThatIsAllMarkupIsUnavailable() async {
        let outcome = await fetcher(body: "<style>.a{color:red}</style>")
            .text(at: URL(string: "https://example.com/notes")!)

        #expect(outcome == .unavailable)
    }
}
