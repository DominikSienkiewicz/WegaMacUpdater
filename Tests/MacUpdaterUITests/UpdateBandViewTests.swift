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
        for diameter in [WegaLayout.bandButtonSize, WegaLayout.bandButtonCompactSize, WegaLayout.bandButtonNarrowSize] {
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
            sources: [
                .init(token: "brew", isVerified: true), .init(token: "mas", isVerified: true),
                .init(token: "npm", isVerified: false), .init(token: "apki", isVerified: true),
            ],
            wegaLine: "Mam kilka rzeczy do zaktualizowania, a jedna z nich jest naprawdę pilna i wymaga uwagi"
        )
    }

    func testTheLayoutRuleSwitchesAtTheBreakpoint() {
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 479), .narrow)
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 480), .compact)
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 819), .compact)
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 820), .regular)
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 740), .compact)
        XCTAssertEqual(UpdateBandLayout.style(forWidth: 380), .narrow)
    }

    func testEachLayoutPicksItsButtonDiameter() throws {
        XCTAssertEqual(UpdateBandLayout.regular.buttonDiameter, WegaLayout.bandButtonSize)
        XCTAssertEqual(UpdateBandLayout.compact.buttonDiameter, WegaLayout.bandButtonCompactSize)
        XCTAssertEqual(UpdateBandLayout.narrow.buttonDiameter, WegaLayout.bandButtonNarrowSize)
        XCTAssertEqual(WegaLayout.bandButtonNarrowSize, 80)
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        XCTAssertTrue(view.contains("diameter: layout.buttonDiameter"))
    }

    /// A 980 pt window with the inspector open leaves the band about 368 pt; the narrow layout
    /// gives Wega's width to the text instead of overflowing the border.
    func testTheNarrowBandFitsTheInspectorOpenWindow() throws {
        for progress in [nil, ScanProgress.running(.npm)] {
            let band = UpdateBand(
                presentation: fullPresentation, refreshProgress: progress, onShowPlan: {},
                action: { _ in Color.clear.frame(width: WegaLayout.bandButtonNarrowSize, height: WegaLayout.bandButtonNarrowSize) }
            )
            .frame(width: 368)
            let size = NSHostingView(rootView: band).fittingSize
            XCTAssertLessThanOrEqual(size.width, 368, "refreshing \(progress != nil)")
            XCTAssertEqual(size.height, WegaLayout.bandHeight, "refreshing \(progress != nil)")
        }
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        let lower = try XCTUnwrap(text.range(of: "private func content(")).upperBound
        let upper = try XCTUnwrap(text.range(of: "private func textColumn(")).lowerBound
        let content = text[lower..<upper]
        let narrow = try XCTUnwrap(content.range(of: "case .narrow:"), "the narrow branch")
        XCTAssertFalse(content[narrow.upperBound...].contains("WegaHead("), "the narrow band draws no Wega")
    }

    func testTheBandNeverChangesHeight() {
        for progress in [nil, ScanProgress.running(.npm)] {
            for width in [240, 368, 380, 520, 700, 819, 820, 1100] as [CGFloat] {
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

    func testOnlyAVerifiedSourceWearsACheck() throws {
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        XCTAssertTrue(text.contains("chip.isVerified ? \"✓ \" + chip.token : chip.token"),
                      "a source that did not answer shows its bare token")
        XCTAssertEqual(text.components(separatedBy: "\"✓ \"").count, 2, "the check is drawn in one place only")
    }

    func testTheBandShowsOnlyWithResults() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let lower = try XCTUnwrap(view.range(of: "private var resultsView: some View")).lowerBound
        let upper = try XCTUnwrap(view.range(of: "private var listHeader: some View")).lowerBound
        let results = view[lower..<upper]
        XCTAssertTrue(results.contains("if hasResults"))
        XCTAssertTrue(results.contains("resultsBand"))
        XCTAssertTrue(results.contains("resultsHeading"), "no results keep today's heading")
        let column = try XCTUnwrap(view.range(of: "private var listColumn: some View")).lowerBound
        XCTAssertTrue(view[column...].prefix(200).contains("if !hasResults"))
        let detail = try source("Sources/MacUpdater/DetailColumn.swift")
        XCTAssertTrue(detail.contains("wegaLine: quip ?? wegaState.line"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
