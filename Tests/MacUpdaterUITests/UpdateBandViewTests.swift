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
                presentation: fullPresentation, refreshProgress: progress, planLinkEnabled: true, onShowPlan: {},
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
                    presentation: fullPresentation, refreshProgress: progress, planLinkEnabled: true, onShowPlan: {},
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
            presentation: fullPresentation, refreshProgress: .running(.npm), planLinkEnabled: true, onShowPlan: {},
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
        XCTAssertTrue(
            text[strip.upperBound...].prefix(200).contains(".environment(\\.colorScheme, .dark)"),
            "the strip's spinner and primary fills resolve for the dark band in the light appearance"
        )
    }

    /// A running update owns the screen, the plan preview included, and a sheet opened mid-run
    /// would cover the run's stop button.
    func testTheBandsEdgesStayQuiet() throws {
        XCTAssertEqual(WegaLayout.bandSummaryWidth, 190, "spec §4.3 allows 150–190")
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        XCTAssertTrue(text.contains("@Environment(\\.colorSchemeContrast) private var contrast"))
        XCTAssertTrue(text.contains("if contrast != .increased {"), "no glows under Increase Contrast")
        XCTAssertTrue(text.contains("color.opacity(0.45)"))
        XCTAssertFalse(text.contains("color.opacity(0.6)"))
        let theme = try source("Sources/MacUpdater/WegaTheme.swift")
        let rim = try XCTUnwrap(theme.range(of: "static let wegaBandButtonRim"))
        XCTAssertTrue(
            theme[rim.upperBound...].prefix(while: { $0 != "\n" }).contains("WegaPalette.caramel.dark"),
            "the rim is caramel's dark value, derived as the glows derive theirs"
        )
    }

    func testThePlanLinkStandsDownWhenDisabled() throws {
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        let link = try XCTUnwrap(text.range(of: "private var planLink: some View")).upperBound
        let planLink = text[link...].prefix(600)
        XCTAssertTrue(planLink.contains(".disabled(!planLinkEnabled)"))
        XCTAssertTrue(
            planLink.contains("planLinkEnabled ? Color.wegaBandAccentText : Color.wegaBandSecondaryText.opacity("),
            "a disabled link dims itself, since its foreground is explicit"
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
        var heads = 0
        var rest = text.startIndex..<text.endIndex
        while let head = text.range(of: "WegaHead(", range: rest) {
            XCTAssertTrue(
                text[head.upperBound...].prefix(200).contains(".accessibilityHidden(true)"),
                "every mascot is hidden from VoiceOver (occurrence \(heads + 1))"
            )
            heads += 1
            rest = head.upperBound..<text.endIndex
        }
        XCTAssertEqual(heads, 2, "the regular and compact layouts draw Wega; the narrow one does not")
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

    /// The band shows only when there is something to update. A result that only waits for
    /// restarts keeps today's heading ("Wszystko aktualne"), while the list still shows it.
    func testTheBandShowsOnlyWithResults() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let lower = try XCTUnwrap(view.range(of: "private var resultsView: some View")).lowerBound
        let upper = try XCTUnwrap(view.range(of: "private var listHeader: some View")).lowerBound
        let results = view[lower..<upper]
        XCTAssertTrue(results.contains("if hasUpdates {"))
        XCTAssertTrue(results.contains("resultsBand"))
        XCTAssertFalse(results.contains("hasResults"), "restarts alone do not bring the band")
        let otherwise = try XCTUnwrap(results.range(of: "if !hasUpdates {"), "no updates keep today's heading")
        XCTAssertTrue(
            results[otherwise.upperBound...].drop(while: \.isWhitespace).hasPrefix("resultsHeading"),
            "the heading is the band's other branch"
        )
        XCTAssertTrue(view.contains("private var hasUpdates: Bool {\n        !(allItems.isEmpty && visibleManual.isEmpty)\n    }"))
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
