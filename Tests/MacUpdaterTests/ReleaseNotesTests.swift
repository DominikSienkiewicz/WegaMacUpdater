import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("ReleaseNotes")
struct ReleaseNotesTests {

    @Test func htmlInitialiserStripsMarkupIntoOneEntry() {
        let notes = ReleaseNotes(html: "<p>Fixed <b>a crash</b></p>", version: "2.0.0")

        #expect(notes.history.notes.count == 1)
        #expect(notes.history.notes.first?.version == "2.0.0")
        #expect(notes.history.notes.first?.body == "Fixed a crash")
        #expect(notes.isEmpty == false)
    }

    @Test func htmlThatCollapsesToNothingProducesEmptyNotes() {
        let notes = ReleaseNotes(html: "<style>.a{color:red}</style>")

        #expect(notes.history.notes.isEmpty)
        #expect(notes.isEmpty)
    }

    @Test func aLinkAloneIsNotEmpty() {
        let notes = ReleaseNotes(history: ReleaseHistory(notes: [], omitted: 0),
                                 link: URL(string: "https://example.com/notes")!)

        #expect(notes.history.notes.isEmpty)
        #expect(notes.isEmpty == false)
    }

    @Test func aLinkAloneHasNothingToRenderYet() {
        let notes = ReleaseNotes(history: ReleaseHistory(notes: [], omitted: 0),
                                 link: URL(string: "https://example.com/notes")!)

        #expect(notes.isEmpty == false)
        #expect(notes.hasRenderableNotes == false)
    }

    @Test func entriesMeanThereIsSomethingToRender() {
        let notes = ReleaseNotes(html: "Fixed a crash", version: "2.0.0")

        #expect(notes.hasRenderableNotes)
    }

    @Test func plainTextJoinsEveryEntryForTriage() {
        let notes = ReleaseNotes(history: ReleaseHistory(notes: [
            ReleaseNote(version: "2.0.0", publishedAt: nil, body: "New icon"),
            ReleaseNote(version: "1.9.0", publishedAt: nil, body: "Fixes CVE-2026-1234"),
        ], omitted: 0), link: nil)

        #expect(ReleaseNotesTriage.heuristic(notes.plainText).isLikelySecurityFix)
    }

    @Test func decodesTheLegacyStringShape() throws {
        // A snapshot written before this change stored raw HTML in a bare string.
        let json = Data(#"{"releaseNotes":"<p>Old &amp; crusty</p>"}"#.utf8)
        struct Box: Decodable { var releaseNotes: ReleaseNotes? }

        let box = try JSONDecoder().decode(Box.self, from: json)

        #expect(box.releaseNotes?.history.notes.count == 1)
        #expect(box.releaseNotes?.history.notes.first?.body == "Old & crusty")
        #expect(box.releaseNotes?.history.notes.first?.version == "")
        #expect(box.releaseNotes?.history.notes.first?.publishedAt == nil)
    }

    @Test func roundTripsTheCurrentShape() throws {
        let original = ReleaseNotes(
            history: ReleaseHistory(notes: [ReleaseNote(version: "3.1.0", publishedAt: nil, body: "Faster")], omitted: 4),
            link: URL(string: "https://example.com/notes")!
        )

        let restored = try JSONDecoder().decode(
            ReleaseNotes.self, from: JSONEncoder().encode(original)
        )

        #expect(restored == original)
    }
}
