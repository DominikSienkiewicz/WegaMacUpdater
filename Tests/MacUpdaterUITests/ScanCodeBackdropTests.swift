import Foundation
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// Owner, 2026-11-22: during a rescan the screen showed no Wega sniffing binary code, so it was
/// not clear that the scan was running. UXP-13 had left only the ±2.4° head-bob in the band,
/// which reads as a still picture. While a scan runs in place, the code Wega sniffs streams
/// behind her again, across the band. The stream itself never lies on the rows (the scanner over
/// them is `ScanListVeil`).
@Suite("A scan in place streams the code Wega sniffs")
struct ScanCodeBackdropTests {
    @Test func theStreamRunsOnlyWhileAScanRuns() {
        #expect(ScanCodeBackdrop.drawsStream(isScanning: true, contrast: .standard))
        #expect(!ScanCodeBackdrop.drawsStream(isScanning: false, contrast: .standard))
        #expect(!ScanCodeBackdrop.drawsStream(isScanning: false, contrast: .increased))
    }

    /// Increase Contrast drops the band's glows; the code behind the text goes with them.
    @Test func increasedContrastKeepsTheTextOnAPlainGround() {
        #expect(!ScanCodeBackdrop.drawsStream(isScanning: true, contrast: .increased))
    }

    @Test func theBackdropIsTheSceneStream() throws {
        let scene = try source("Sources/MacUpdater/SniffingScene.swift")
        let start = try #require(scene.range(of: "struct ScanCodeBackdrop: View"))
        let body = scene[start.upperBound...].prefix(1400)
        #expect(body.contains("@Environment(\\.colorSchemeContrast)"))
        #expect(body.contains("if Self.drawsStream(isScanning: isScanning, contrast: contrast) {"))
        #expect(body.contains("BinaryStream(lanes: lanes, color: color)"))
    }

    /// The band draws the code on its gradient and inside its rounded clip, so it never spills
    /// past the band's corners and never lies on the text it sits behind.
    @Test func theBandStreamsTheCodeBehindItsContentWhileItScans() throws {
        let band = try source("Sources/MacUpdater/UpdateBand.swift")
        let start = try #require(band.range(of: "private var backdrop: some View"))
        let backdrop = band[start.upperBound...].prefix(900)
        let gradient = try #require(backdrop.range(of: "LinearGradient("))
        let stream = try #require(backdrop.range(of: "ScanCodeBackdrop(isScanning: scan != nil, color: .wegaBandAccentText)"))
        let clip = try #require(backdrop.range(of: ".clipShape("))
        #expect(gradient.lowerBound < stream.lowerBound, "the code streams over the gradient, not under it")
        #expect(stream.lowerBound < clip.lowerBound, "inside the band's rounded clip")
    }

    /// Owner, 2026-11-22 — every result now carries the band, „Wszystko aktualne” included, so the
    /// band's stream is the only one: the plain heading that had its own is gone.
    @Test func theBandCarriesTheStreamOverEveryResult() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(!view.contains("ScanCodeBackdrop("), "no second stream beside the band's")
        #expect(!view.contains("private var resultsHeading"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
