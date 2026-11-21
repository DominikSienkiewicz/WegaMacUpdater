import Foundation
import Testing
@testable import WegaMacUpdater

/// 0.8.0 promised that **Check now** and **⌘R** keep the list on screen, stood down, while the
/// band reports the scan. The overlay that stood the rows down drew `.regularMaterial`, and on
/// the dark window that material blurs a row of text into nothing: the owner saw an empty list
/// column with one pill in it — fourteen updates in the scope bar and not one row. A thinner
/// veil and the scanning scene over it followed; UXP-13 took both away (approved change: nothing
/// lies on the rows). The rows stay as they are, inert, and the scan is told by the band and the
/// list header, with Wega sniffing in the band or next to the phase strip.
///
/// So these pin the absence of a layer, not its tuning.
@Suite("A scan in place keeps the rows visible")
struct ScanInPlaceKeepsRowsVisibleTests {
    @Test func nothingIsDrawnOverTheRows() throws {
        let screen = try screenBodySource()

        #expect(!screen.contains(".overlay"), "no veil, scene or material lies on the rows during a scan")
        #expect(screen.contains(".disabled(!ScanSelectionGate.allowsSelection(isRefreshing: scan.isRefreshing))"),
                "the rows are still a report, not a menu, while the scan replaces them")
        let overlay = try source("Sources/MacUpdater/ScanBusyOverlay.swift")
        #expect(!overlay.contains("struct ScanBusyOverlay"), "the scan's veil over the list is gone")
        #expect(!overlay.contains("Material"))
    }

    @Test func wegaSniffsBesideTheRowsNotOverThem() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")

        #expect(view.contains("scan: scan.isRefreshing ? scanPresentation : nil"),
                "the band carries the scan, Wega included")
        #expect(view.contains("WegaHead(pose: .sniff, size: 28).sniffing(true).accessibilityHidden(true)"),
                "with no band, Wega sniffs next to the phase strip")
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
