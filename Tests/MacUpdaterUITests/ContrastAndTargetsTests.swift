import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// UXP-22 — what a state says was drawn in `.tertiary`, below the 4.5:1 a sentence needs; the run's
/// veil ignored Reduce Transparency; the banner's close and the plan link were smaller than the
/// 28×28 pt macOS asks for; and the log scrolled with an animation under Reduce Motion.
///
/// `.secondary` is a system style, so its contrast is the system's: these tests pin the styles.
@Suite("Contrast, transparency and targets") @MainActor
struct ContrastAndTargetsTests {
    @Test func stateTextIsSecondaryNotTertiary() throws {
        let runViews = try source("Sources/MacUpdater/UpdateBandRunViews.swift")
        #expect(!runViews.contains(".tertiary"), "the run's stage, note and stop")
        let trust = try source("Sources/MacUpdater/TrustPanel.swift")
        for label in ["Weryfikowanie…", "Weryfikacja niedostępna", "pierwsze sprawdzenie podpisu", "podpis bez zmian"] {
            let at = try #require(trust.range(of: "tr(\"\(label)\")"), "\(label)").upperBound
            #expect(trust[at...].prefix(160).contains(".foregroundStyle(.secondary)"), "\(label)")
        }
        #expect(!(try source("Sources/MacUpdater/ScanPhaseStrip.swift")).contains("AnyShapeStyle(.tertiary)"))
        #expect(try source("Sources/MacUpdater/UpdateView.swift")
            .contains("Text(tr(\"Sprawdzam rozmiary pobrań…\")).font(.wega(.subheadline)).foregroundStyle(.secondary)"))
    }

    @Test func reduceTransparencyRemovesTheDimming() throws {
        #expect(ScanListVeil.scrim(reduceTransparency: true) == 0)
        #expect(ScanListVeil.scrim(reduceTransparency: false) > 0)
        for file in ["UpdateBand.swift", "UpdateBandRunViews.swift", "UpdateBandRunPresentation.swift",
                     "UpdateBandSummaryViews.swift", "ScanListVeil.swift"] {
            let text = try source("Sources/MacUpdater/\(file)")
            #expect(!text.contains(".glassEffect("), "\(file)")
            #expect(!text.contains("Material"), "\(file)")
        }
    }

    @Test func theRunLocksTheListIndependentlyOfTheVeil() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("screenBody\n                .disabled(!ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating))"))
        #expect(!view.contains("reduceTransparency"), "the lock never asks how the veil is drawn")
        let results = try #require(view.range(of: "private var resultsView: some View")).lowerBound
        let header = try #require(view.range(of: "private var listHeader: some View", range: results..<view.endIndex)).lowerBound
        #expect(view[results..<header].contains("ScanListVeil(mode: .updating)"))
        #expect(try source("Sources/MacUpdater/ScanListVeil.swift").contains(".allowsHitTesting(false)"))
        let shared = try source("Sources/MacUpdater/SharedViews.swift")
        let row = try #require(shared.range(of: "struct PackageRow: View")).lowerBound
        let rowEnd = try #require(shared.range(of: "// MARK: - Rollback badge", range: row..<shared.endIndex)).lowerBound
        #expect(shared[row..<rowEnd].contains(".accessibilityActions {\n            if isEnabled {"),
                "VoiceOver's row actions follow the disabled screen")
        #expect(!ScanSelectionGate.allowsScreenInteraction(isUpdating: true))
        #expect(!ScanSelectionGate.allowsListSelection(isRefreshing: false, isUpdating: true))
    }

    @Test func smallTargetsGrowAndTheLogStopsAnimating() throws {
        #expect(try source("Sources/MacUpdater/WegaCallout.swift").contains(".frame(width: 28, height: 28)"))
        let band = try source("Sources/MacUpdater/UpdateBand.swift")
        let link = try #require(band.range(of: "private var planLink: some View")).upperBound
        #expect(band[link...].prefix(600).contains(".buttonStyle(.link)"))
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        #expect(support.contains("withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(\"bottom\", anchor: .bottom) }"))
        let log = try #require(support.range(of: "struct BrewLogPanel: View")).upperBound
        let end = try #require(support.range(of: "struct CheckingBar: View", range: log..<support.endIndex)).lowerBound
        #expect(support[log..<end].contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        #expect(support[log..<end].contains(".frame(width: 28, height: 28)"), "the log's close button too")
    }

    /// The close button's 28 pt hit area overhangs the banner's padding instead of making a
    /// one-line banner taller.
    @Test func theLargerCloseTargetLeavesABannerItsHeight() {
        for width in [300, 420, 820] as [CGFloat] {
            let plain = NSHostingView(rootView: WegaCallout(.info, title: "Wega").frame(width: width)).fittingSize.height
            let closable = NSHostingView(rootView: WegaCallout(.info, title: "Wega", onClose: {}).frame(width: width)).fittingSize.height
            #expect(closable == plain, "width \(width): \(closable) pt with the close button, \(plain) pt without")
        }
    }

    /// The log's close button too: the header stays as tall as its title line plus its padding,
    /// which is what it was with the bare 10 pt glyph.
    @Test func theLogHeaderKeepsItsHeightWithTheLargerCloseTarget() {
        let title = NSHostingView(rootView: Text(verbatim: "brew log")
            .font(.wega(.footnote, weight: .semibold, monospaced: true))
            .padding(.vertical, 8)).fittingSize.height
        for width in [320, 560] as [CGFloat] {
            let header = NSHostingView(rootView: BrewLogPanel(lines: [], onClose: {}).header.frame(width: width)).fittingSize.height
            #expect(header == title, "width \(width): the header is \(header) pt, its title line \(title) pt")
        }
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
