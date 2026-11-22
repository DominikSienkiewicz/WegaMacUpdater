import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// Owner, 2026-11-22: during a scan the rows are inert, but nothing on them said so, and people
/// could click them and wonder why nothing happened. Of four sketches the owner chose the scanner:
/// a veil with no material, a honey line sweeping down the visible list, and a centred label.
/// This reverses UXP-13's "nothing lies on the rows" by the owner's decision; what stays from
/// 0.8.0 is that no material blurs the rows into an empty column.
@Suite("A scan over the rows lays the scanner on them") @MainActor
struct ScanListVeilTests {
    @Test func theVeilDimsTheRowsHalfwayAndGoesUnderReduceTransparency() {
        #expect(ScanListVeil.scrim(reduceTransparency: false) == 0.5)
        #expect(ScanListVeil.scrim(reduceTransparency: true) == 0)
    }

    @Test func theLineRunsOnlyWhenMotionIsAllowed() {
        #expect(ScanListVeil.drawsBeam(reduceMotion: false))
        #expect(!ScanListVeil.drawsBeam(reduceMotion: true))
    }

    /// The line enters just above the list, leaves at its bottom edge, and starts again: one
    /// sweep every 2.4 s over the overlay's own height, so a short list is swept as fast as a
    /// long one is.
    @Test func theLineSweepsTheListTopToBottomAndRepeats() {
        #expect(ScanListVeil.beamHeight == 28)
        #expect(ScanListVeil.sweepPeriod == 2.4)
        #expect(ScanListVeil.beamTop(at: 0, height: 200) == -28)
        #expect(ScanListVeil.beamTop(at: 1.2, height: 200) == 86)
        #expect(ScanListVeil.beamTop(at: 2.4, height: 200) == -28)
        #expect(abs(ScanListVeil.beamTop(at: 3.6, height: 100) - 36) < 0.001)
    }

    @Test func theLabelSaysWhenTheListUnlocks() {
        withLanguage(.en) {
            #expect(tr("Lista odblokuje się po skanie") == "The list unlocks when the scan finishes")
        }
    }

    @Test func theVeilTakesNoClicksAndBlursNothing() throws {
        let veil = try source("Sources/MacUpdater/ScanListVeil.swift")
        #expect(!veil.contains("Material"), "a material blurred the rows into an empty column in 0.8.0")
        #expect(veil.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        #expect(veil.contains("@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency"))
        #expect(veil.contains(".opacity(Self.scrim(reduceTransparency: reduceTransparency))"))
        #expect(veil.contains(".allowsHitTesting(false)"), "the list still scrolls under it")
        let branch = try #require(veil.range(of: "if Self.drawsBeam(reduceMotion: reduceMotion) {"))
        let timeline = try #require(veil.range(of: "TimelineView(.animation"))
        #expect(branch.upperBound < timeline.lowerBound, "under Reduce Motion no timeline is built at all")
        #expect(veil.components(separatedBy: "TimelineView(").count == 2)
        #expect(veil.contains(".accessibilityLabel(tr(\"Lista odblokuje się po skanie\"))"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
