import Foundation
import Testing
@testable import WegaMacUpdater

/// 0.8.0 promised that **Check now** and **⌘R** keep the list on screen, stood down, while the
/// band reports the scan. The overlay that stood the rows down drew `.regularMaterial`, and on
/// the dark window that material blurs a row of text into nothing: the owner saw an empty list
/// column with one pill in it — fourteen updates in the scope bar and not one row — and, since
/// UX-19 took the scanning scene out of the overlay, nothing in that column moved for the
/// whole scan.
///
/// Against the 0.8.0 overlay both tests fail on their expectations: it draws a material, its
/// veil is the stub's fully opaque 1.0, and its note has no live indicator.
@Suite("A scan in place keeps the rows visible")
struct ScanInPlaceKeepsRowsVisibleTests {
    @Test func theRowsAreDimmedNotBlurredAway() throws {
        let overlay = try overlayViewSource()

        #expect(!overlay.contains("Material"),
                "a material of any thickness blurs the rows into an empty column")
        #expect(overlay.contains(".background(Color(nsColor: .windowBackgroundColor).opacity(Self.scrimOpacity))"),
                "the rows are stood down by a veil of the window's own background")
        #expect(ScanBusyOverlay.scrimOpacity <= 0.6, "every row stays legible under the veil")
        #expect(ScanBusyOverlay.scrimOpacity >= 0.3, "and still reads as stood down")
    }

    @Test func theListShowsThatTheScanIsRunning() throws {
        let overlay = try overlayViewSource()

        #expect(overlay.contains("ProgressView()"),
                "something over the list moves for as long as the scan runs")
        #expect(overlay.contains("presentation.phaseLabel"),
                "and the note names the command the scan is running now")
    }

    /// `ScanBusyOverlay`'s own declaration, comments left out, so a doc comment that explains
    /// why there is no material cannot satisfy or fail an assertion about the code.
    private func overlayViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/MacUpdater/ScanBusyOverlay.swift"), encoding: .utf8
        )
        let start = try #require(text.range(of: "struct ScanBusyOverlay: View"))
        return text[start.lowerBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
