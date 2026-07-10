import XCTest
@testable import MacUpdaterCore

/// F1 — Sparkle appcasts and the JetBrains API hand back HTML, often inside CDATA, written
/// by whoever ships the app. It gets rendered in Wega's window, so it is untrusted input:
/// scripts, styles and markup come out, text goes in.
final class ReleaseNotesTextTests: XCTestCase {
    func testPlainTextPassesThroughUnchanged() {
        XCTAssertEqual(ReleaseNotesText.plain(fromHTML: "Fixed a crash."), "Fixed a crash.")
    }

    func testTagsAreStripped() {
        XCTAssertEqual(
            ReleaseNotesText.plain(fromHTML: "<p>Fixed a <b>crash</b>.</p>"),
            "Fixed a crash."
        )
    }

    /// The one that matters: a hostile appcast must not smuggle a script through.
    func testScriptContentIsRemovedEntirelyNotJustItsTags() {
        let html = "<p>Notes</p><script>alert('pwned')</script>"
        let text = ReleaseNotesText.plain(fromHTML: html)
        XCTAssertEqual(text, "Notes")
        XCTAssertFalse(text.contains("alert"))
    }

    func testStyleContentIsRemovedEntirely() {
        let text = ReleaseNotesText.plain(fromHTML: "<style>body{color:red}</style><p>Notes</p>")
        XCTAssertEqual(text, "Notes")
        XCTAssertFalse(text.contains("color"))
    }

    func testListItemsBecomeSeparateLines() {
        XCTAssertEqual(
            ReleaseNotesText.plain(fromHTML: "<ul><li>First</li><li>Second</li></ul>"),
            "First\nSecond"
        )
    }

    func testLineBreakTagsBecomeNewlines() {
        XCTAssertEqual(ReleaseNotesText.plain(fromHTML: "One<br>Two<br/>Three"), "One\nTwo\nThree")
    }

    func testHTMLEntitiesAreDecoded() {
        XCTAssertEqual(
            ReleaseNotesText.plain(fromHTML: "AT&amp;T &lt;3 &quot;quotes&quot;"),
            "AT&T <3 \"quotes\""
        )
    }

    func testWhitespaceIsCollapsedAndTrimmed() {
        XCTAssertEqual(ReleaseNotesText.plain(fromHTML: "  <p>  Lots   of   space  </p>  "), "Lots of space")
    }

    func testEmptyHTMLYieldsEmptyString() {
        XCTAssertEqual(ReleaseNotesText.plain(fromHTML: "<p></p>"), "")
    }

    /// Unclosed tags are a fact of vendor HTML; do not lose the rest of the text over them.
    func testUnclosedTagDoesNotSwallowTheRemainingText() {
        XCTAssertEqual(ReleaseNotesText.plain(fromHTML: "Before <b>after"), "Before after")
    }
}
