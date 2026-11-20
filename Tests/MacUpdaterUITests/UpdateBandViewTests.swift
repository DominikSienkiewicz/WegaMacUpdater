import AppKit
import MacUpdaterCore
import SwiftUI
import XCTest

@testable import WegaMacUpdater

/// The Updates band's round button and band view: fixed geometry and the structure that keeps
/// VoiceOver order and the dark palette honest.
@MainActor
final class UpdateBandViewTests: XCTestCase {

    private func fittingSize(ofButtonWith diameter: CGFloat, disabled: Bool) -> CGSize {
        let button = UpdateBandButton(
            title: "Aktualizuj", count: 3, accessibilityLabel: "x", diameter: diameter
        ) {}
        .disabled(disabled)
        return NSHostingView(rootView: button).fittingSize
    }

    func testTheButtonIsExactlyItsDiameter() {
        for diameter in [WegaLayout.bandButtonSize, WegaLayout.bandButtonCompactSize] {
            for disabled in [false, true] {
                XCTAssertEqual(
                    fittingSize(ofButtonWith: diameter, disabled: disabled),
                    CGSize(width: diameter, height: diameter),
                    "diameter \(diameter), disabled \(disabled)"
                )
            }
        }
    }

    func testTheButtonDrawsItsStateFromIsEnabled() throws {
        let text = try source("Sources/MacUpdater/UpdateBandButton.swift")
        for literal in [
            "@Environment(\\.isEnabled)", ".contentShape(Circle())",
            ".accessibilityLabel(accessibilityLabel)", "Button(action: action)",
        ] {
            XCTAssertTrue(text.contains(literal), literal)
        }
        XCTAssertFalse(text.contains(".system(size:"))
    }

    // MARK: - The band

    private var fullPresentation: UpdateBandPresentation {
        UpdateBandPresentation(
            totalCount: 22, urgentCount: 4, queueCount: 12,
            protectionText: "12 z automatycznym cofnięciem",
            lastCheck: Date(timeIntervalSince1970: 1_800_000_000), freshness: .stale,
            activeSources: [.homebrew, .appStore, .npm, .manual],
            wegaLine: "Mam kilka rzeczy do zaktualizowania, a jedna z nich jest naprawdę pilna i wymaga uwagi"
        )
    }

    func testTheLayoutRuleSwitchesAtTheBreakpoint() {
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 819), .compact)
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 820), .regular)
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 740), .compact)
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 380), .compact)
    }

    func testTheBandNeverChangesHeight() {
        for progress in [nil, ScanProgress.running(.npm)] {
            for width in [380, 520, 700, 819, 820, 1100] as [CGFloat] {
                let band = UpdateBand(
                    presentation: fullPresentation, refreshProgress: progress, onShowPlan: {},
                    action: { _ in Color.clear.frame(width: 96, height: 96) }
                )
                .frame(width: width)
                XCTAssertEqual(
                    NSHostingView(rootView: band).fittingSize.height, WegaLayout.bandHeight,
                    "width \(width), refreshing \(progress != nil)"
                )
            }
        }
    }

    func testTheRefreshingEyebrowNeverWidensOrGrowsTheBand() throws {
        let band = UpdateBand(
            presentation: fullPresentation, refreshProgress: .running(.npm), onShowPlan: {},
            action: { _ in Color.clear.frame(width: 96, height: 96) }
        )
        .frame(width: 380)
        let size = NSHostingView(rootView: band).fittingSize
        XCTAssertLessThanOrEqual(size.width, 380)
        XCTAssertEqual(size.height, WegaLayout.bandHeight)
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        let strip = try XCTUnwrap(text.range(of: "ScanPhaseStrip(progress: refreshProgress)"))
        XCTAssertTrue(
            text[strip.upperBound...].prefix(120).contains(".clipped()"),
            "the strip is clipped to its column"
        )
    }

    func testTheBandIsReadInOrder() throws {
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        for literal in [
            ".accessibilityAddTraits(.isHeader)", "ScanPhaseStrip(progress: refreshProgress)",
            ".frame(height: WegaLayout.bandHeight)", "UpdateBandLayout.style(forWidth:",
            ".foregroundStyle(Color.wegaBandText)",
        ] {
            XCTAssertTrue(text.contains(literal), literal)
        }
        let head = try XCTUnwrap(text.range(of: "WegaHead("))
        XCTAssertTrue(
            text[head.upperBound...].prefix(200).contains(".accessibilityHidden(true)"),
            "the mascot is hidden from VoiceOver"
        )
        for forbidden in [".glassEffect(", "Color.wegaToffee", "Color.wegaSuccess", "Color.wegaHoney"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
