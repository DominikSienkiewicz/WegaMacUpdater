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
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let bar = try #require(support.range(of: "struct UpgradeProgressBar: View")).upperBound
        #expect(!support[bar...].prefix(700).contains(".foregroundStyle(.tertiary)"))
        let trust = try source("Sources/MacUpdater/TrustPanel.swift")
        for label in ["Weryfikowanie…", "Weryfikacja niedostępna", "pierwsze sprawdzenie podpisu", "podpis bez zmian"] {
            let at = try #require(trust.range(of: "tr(\"\(label)\")"), "\(label)").upperBound
            #expect(trust[at...].prefix(160).contains(".foregroundStyle(.secondary)"), "\(label)")
        }
        #expect(!(try source("Sources/MacUpdater/ScanPhaseStrip.swift")).contains("AnyShapeStyle(.tertiary)"))
        #expect(try source("Sources/MacUpdater/UpdateView.swift")
            .contains("Text(tr(\"Sprawdzam rozmiary pobrań…\")).font(.wega(.subheadline)).foregroundStyle(.secondary)"))
    }

    @Test func reduceTransparencyRemovesTheVeilInsteadOfHidingTheRows() throws {
        #expect(UpdateRunOverlay<EmptyView>.scrim(reduceTransparency: false) == 0.5)
        #expect(UpdateRunOverlay<EmptyView>.scrim(reduceTransparency: true) == 0)
        let overlay = try source("Sources/MacUpdater/UpdateRunOverlay.swift")
        #expect(overlay.contains("@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency"))
        #expect(overlay.contains(".opacity(Self.scrim(reduceTransparency: reduceTransparency))"))
        #expect(overlay.contains(".background(Color.wegaRecessedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))"),
                "the note keeps a surface of its own without glass")
    }

    /// With no veil drawn, nothing about the run's lock may depend on drawing it: the screen is
    /// disabled by the run itself, the overlay still takes the clicks the veil took, and the
    /// selection refuses every change the run did not start.
    @Test func theRunLocksTheListWithoutTheVeil() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("screenBody\n                .disabled(!ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating))"))
        #expect(!view.contains("reduceTransparency"), "the lock never asks how the veil is drawn")
        let overlay = try source("Sources/MacUpdater/UpdateRunOverlay.swift")
        let body = try #require(overlay.range(of: "var body: some View")).upperBound
        let veil = try #require(overlay.range(of: ".opacity(Self.scrim(reduceTransparency: reduceTransparency))", range: body..<overlay.endIndex))
        #expect(overlay[veil.upperBound...].prefix(120).contains(".contentShape(Rectangle())"),
                "a transparent veil still takes the clicks")
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

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
