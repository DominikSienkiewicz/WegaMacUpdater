import Foundation
import Testing
@testable import WegaMacUpdater

/// 0.8.0 promised that **Check now** and **⌘R** keep the list on screen, stood down, while the
/// band reports the scan. The overlay that stood the rows down drew `.regularMaterial`, and on
/// the dark window that material blurs a row of text into nothing: the owner saw an empty list
/// column with one pill in it — fourteen updates in the scope bar and not one row. A thinner
/// veil and the scanning scene over it followed; UXP-13 took both away. On 2026-11-22 the owner
/// asked for a cover again, because people clicked rows that could not answer, and chose the
/// scanner (`ScanListVeil`): a half veil, a sweeping line and a label, with nothing blurred.
///
/// So these pin that the scanner is the one layer on the rows and that no material comes back.
@Suite("A scan in place keeps the rows visible")
struct ScanInPlaceKeepsRowsVisibleTests {
    @Test func onlyTheScannerLiesOnTheRows() throws {
        let screen = try screenBodySource()

        #expect(screen.components(separatedBy: ".overlay").count == 2, "one layer lies on the rows during a scan")
        #expect(screen.contains("ScanListVeil()"), "and it is the scanner")
        #expect(screen.contains(".disabled(!ScanSelectionGate.allowsSelection(isRefreshing: scan.isRefreshing))"),
                "the rows are still a report, not a menu, while the scan replaces them")
        let overlay = try source("Sources/MacUpdater/ScanBusyOverlay.swift")
        #expect(!overlay.contains("struct ScanBusyOverlay"), "the old scene over the list stays gone")
        #expect(!overlay.contains("Material"))
        #expect(!(try source("Sources/MacUpdater/ScanListVeil.swift")).contains("Material"),
                "no material blurs the rows into an empty column")
    }

    @Test func wegaSniffsBesideTheRowsNotOverThem() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")

        #expect(view.contains("scan: scan.isRefreshing ? scanPresentation : nil"),
                "the band carries the scan, Wega included")
        #expect(!view.contains("WegaHead(pose: .sniff"),
                "the band stands over every result (owner, 2026-11-22), so Wega sniffs in it, never beside a heading")
        #expect(!view.contains("ScanBusyOverlay("))
    }

    /// `screenBody`'s declaration, comments left out, so a comment that explains why nothing is
    /// drawn over the rows cannot satisfy or fail an assertion about the code.
    private func screenBodySource() throws -> String {
        let text = try source("Sources/MacUpdater/UpdateView.swift")
        let start = try #require(text.range(of: "private var screenBody: some View"))
        let end = try #require(text.range(of: "private var scopeBar: some View", range: start.upperBound..<text.endIndex))
        return text[start.lowerBound..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
