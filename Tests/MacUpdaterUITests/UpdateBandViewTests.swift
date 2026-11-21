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

    /// UXP-13 — while a scan runs the ring takes the button's place, so it must be the button's
    /// size exactly: anything else moves the text column the moment a scan starts or ends.
    func testTheRingIsExactlyTheButtonsDiameter() {
        for diameter in [WegaLayout.bandButtonSize, WegaLayout.bandButtonCompactSize, WegaLayout.bandButtonNarrowSize] {
            for showsWega in [false, true] {
                let ring = UpdateBandScanRing(completed: 2, total: 4, diameter: diameter, showsWega: showsWega)
                XCTAssertEqual(
                    NSHostingView(rootView: ring).fittingSize, CGSize(width: diameter, height: diameter),
                    "diameter \(diameter), Wega \(showsWega)"
                )
            }
        }
    }

    /// C2 stage 3 — while an update runs its ring takes the button's place, at the button's size.
    func testTheRunRingIsExactlyTheButtonsDiameter() {
        for diameter in [WegaLayout.bandButtonSize, WegaLayout.bandButtonCompactSize, WegaLayout.bandButtonNarrowSize] {
            let ring = UpdateBandRunRing(completed: 12, total: 40, diameter: diameter, accessibilityValue: "x")
            XCTAssertEqual(NSHostingView(rootView: ring).fittingSize, CGSize(width: diameter, height: diameter), "diameter \(diameter)")
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
            protectionText: "Sprawdzam możliwość cofnięcia",
            lastCheck: Date(timeIntervalSince1970: 1_800_000_000), freshness: .stale,
            sources: [
                .init(token: "brew", isVerified: true), .init(token: "mas", isVerified: true),
                .init(token: "npm", isVerified: false), .init(token: "producenci", isVerified: true),
            ],
            wegaLine: "Mam kilka rzeczy do zaktualizowania, a jedna z nich jest naprawdę pilna i wymaga uwagi"
        )
    }

    /// The scan state with its longest copy: the vendor phase, its count and a plural summary.
    private var scanFixture: UpdateBandScanPresentation {
        UpdateBandScanPresentation(
            progress: .running(.manual), catalogRefreshing: false, startedAt: Date(timeIntervalSince1970: 0),
            manual: ManualScanProgress(checkedApps: 12, totalApps: 31), foundSoFar: 22
        )
    }

    /// The scan state before the vendor phase: the line says why selecting waits.
    private var scanNoteFixture: UpdateBandScanPresentation {
        UpdateBandScanPresentation(
            progress: .running(.npm), catalogRefreshing: false, startedAt: Date(timeIntervalSince1970: 0),
            manual: nil, foundSoFar: 22
        )
    }

    /// The run state with its longest stage: a long cask token and a two-digit counter.
    private var runFixture: UpdateBandRunPresentation {
        UpdateBandRunPresentation(progress: UpgradeProgress(completedUnits: 12, totalUnits: 40, stage: .installing(token: "com.microsoft.edgemac")),
                                  startedAt: Date(timeIntervalSince1970: 0), isStopping: false, logShown: false)
    }

    /// The run once a stop is requested: the longer stop label.
    private var runStoppingFixture: UpdateBandRunPresentation {
        UpdateBandRunPresentation(progress: UpgradeProgress(completedUnits: 12, totalUnits: 40, stage: .downloading(token: "microsoft-teams")),
                                  startedAt: Date(timeIntervalSince1970: 0), isStopping: true, logShown: false)
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
        for scan in [nil, scanFixture] {
            let band = UpdateBand(
                presentation: fullPresentation, scan: scan, planLinkEnabled: true, onShowPlan: {},
                action: { _ in Color.clear.frame(width: WegaLayout.bandButtonNarrowSize, height: WegaLayout.bandButtonNarrowSize) }
            )
            .frame(width: 368)
            let size = NSHostingView(rootView: band).fittingSize
            XCTAssertLessThanOrEqual(size.width, 368, "scanning \(scan != nil)")
            XCTAssertEqual(size.height, WegaLayout.bandHeight, "scanning \(scan != nil)")
        }
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        let lower = try XCTUnwrap(text.range(of: "private func content(")).upperBound
        let upper = try XCTUnwrap(text.range(of: "private func textColumn(")).lowerBound
        let content = text[lower..<upper]
        let narrow = try XCTUnwrap(content.range(of: "case .narrow:"), "the narrow branch")
        XCTAssertFalse(content[narrow.upperBound...].contains("WegaHead("), "the narrow band draws no Wega")
    }

    func testTheBandNeverChangesHeight() {
        for language in [AppLanguage.pl, .en] {
            for scan in [nil, scanFixture, scanNoteFixture] {
                for width in [240, 368, 380, 388, 480, 520, 700, 819, 820, 1100] as [CGFloat] {
                    let height = withLanguage(language) {
                        let band = UpdateBand(
                            presentation: fullPresentation, scan: scan, planLinkEnabled: true, onShowPlan: {},
                            action: { _ in Color.clear.frame(width: 96, height: 96) }
                        )
                        .frame(width: width)
                        return NSHostingView(rootView: band).fittingSize.height
                    }
                    XCTAssertEqual(height, WegaLayout.bandHeight, "\(language), width \(width), scanning \(scan != nil)")
                }
            }
        }
    }

    /// C2 stage 3 — the run moved into the band; the band keeps its height in every layout.
    func testTheRunNeverChangesTheBandsHeight() {
        for language in [AppLanguage.pl, .en] {
            for run in [runFixture, runStoppingFixture] {
                for width in [240, 368, 380, 388, 480, 520, 700, 819, 820, 1100] as [CGFloat] {
                    let height = withLanguage(language) {
                        let band = UpdateBand(
                            presentation: fullPresentation, scan: nil, run: run, planLinkEnabled: false, onShowPlan: {},
                            action: { _ in Color.clear.frame(width: 96, height: 96) }
                        )
                        .frame(width: width)
                        return NSHostingView(rootView: band).fittingSize.height
                    }
                    XCTAssertEqual(height, WegaLayout.bandHeight, "\(language), width \(width), stopping \(run.isStopping)")
                }
            }
        }
    }

    /// The frame always reports the band's height, so this measures what it has to hold: the
    /// eyebrow, the headline, the longest stage, the stop and „Pokaż log”.
    func testTheTallestRunStillFitsTheBand() {
        for bandWidth in Self.runBandWidths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            for language in [AppLanguage.pl, .en] {
                for run in [runFixture, runStoppingFixture] {
                    let height = withLanguage(language) {
                        let band = UpdateBand(
                            presentation: presentation(count: 22, note: tr("skan niepełny")),
                            scan: nil, run: run, planLinkEnabled: false, onShowPlan: {},
                            action: { layout in
                                Color.clear.frame(width: layout.buttonDiameter, height: layout.buttonDiameter)
                            }
                        )
                        return NSHostingView(rootView: band.naturalContent(width: bandWidth)).fittingSize.height
                    }
                    XCTAssertLessThanOrEqual(
                        height, WegaLayout.bandHeight,
                        "\(language), band \(bandWidth) pt (\(layout)), stopping \(run.isStopping): content is \(height) pt"
                    )
                }
            }
        }
    }

    func testTheNarrowRunFitsTheInspectorOpenWindow() {
        for language in [AppLanguage.pl, .en] {
            for run in [runFixture, runStoppingFixture] {
                let size = withLanguage(language) {
                    let band = UpdateBand(
                        presentation: fullPresentation, scan: nil, run: run, planLinkEnabled: false, onShowPlan: {},
                        action: { _ in Color.clear.frame(width: WegaLayout.bandButtonNarrowSize, height: WegaLayout.bandButtonNarrowSize) }
                    )
                    .frame(width: 368)
                    return NSHostingView(rootView: band).fittingSize
                }
                XCTAssertLessThanOrEqual(size.width, 368, "\(language), stopping \(run.isStopping)")
                XCTAssertEqual(size.height, WegaLayout.bandHeight, "\(language), stopping \(run.isStopping)")
            }
        }
    }

    /// Cut, the stop label stops saying that it waits for the installs already running, and the
    /// stage stops naming the package. Each must fit its line limit in the column the band draws
    /// it in, at each layout's narrowest width and with the inspector open; the eyebrow must fit
    /// one line.
    func testTheStopLabelAndTheStageAreNeverTruncated() {
        for bandWidth in Self.runBandWidths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            let column = headlineColumnWidth(bandWidth: bandWidth)
            let stopColumn = layout == .regular ? WegaLayout.bandSummaryWidth : column
            let stopFont = Font.wega(.callout, weight: .semibold)
            let lineFont = Font.wega(.callout)
            let eyebrowFont = Font.wega(.caption, weight: .semibold, monospaced: true)
            let allowedStop = height(of: "Ag\nAg", font: stopFont, width: stopColumn)
            let allowedLine = height(of: Array(repeating: "Ag", count: layout.scanLineLimit).joined(separator: "\n"), font: lineFont, width: column)
            for language in [AppLanguage.pl, .en] {
                for run in [runFixture, runStoppingFixture] {
                    let (stop, line, eyebrow) = withLanguage(language) { (run.stopLabel, run.line, run.eyebrow) }
                    let context = "\(language), band \(bandWidth) pt (\(layout)), stopping \(run.isStopping)"
                    let neededStop = height(of: stop, font: stopFont, width: stopColumn)
                    XCTAssertLessThanOrEqual(neededStop, allowedStop, "\(context): \"\(stop)\" needs \(neededStop) pt of \(allowedStop)")
                    // The link-styled button itself wraps the label the way the text does.
                    let stopOnly = UpdateBandRunPresentation(progress: run.progress, startedAt: run.startedAt,
                                                             isStopping: run.isStopping, logShown: true)
                    let drawn = withLanguage(language) {
                        NSHostingView(rootView: UpdateBandRunControls(run: stopOnly, showsNote: false, onStop: {}, onShowLog: {})
                            .frame(width: stopColumn).fixedSize(horizontal: false, vertical: true)).fittingSize.height
                    }
                    XCTAssertEqual(drawn, neededStop, accuracy: 1, "\(context): the stop button draws \(drawn) pt for \(neededStop) pt of text")
                    let neededLine = height(of: line, font: lineFont, width: column)
                    XCTAssertLessThanOrEqual(neededLine, allowedLine, "\(context): \"\(line)\" needs \(neededLine) pt of \(allowedLine)")
                    let eyebrowWidth = NSHostingView(rootView: Text(verbatim: eyebrow).font(eyebrowFont)
                        .tracking(0.8).textCase(.uppercase).fixedSize()).fittingSize.width
                    XCTAssertLessThanOrEqual(eyebrowWidth, column, "\(context): \"\(eyebrow)\" needs \(eyebrowWidth) pt")
                }
            }
        }
    }

    private func height(of text: String, font: Font, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: Text(verbatim: text).font(font).frame(width: width).fixedSize(horizontal: false, vertical: true))
            .fittingSize.height
    }

    func testTheScanningEyebrowNeverWidensOrGrowsTheBand() throws {
        let band = UpdateBand(
            presentation: fullPresentation, scan: scanFixture, planLinkEnabled: true, onShowPlan: {},
            action: { _ in Color.clear.frame(width: 96, height: 96) }
        )
        .frame(width: 380)
        let size = NSHostingView(rootView: band).fittingSize
        XCTAssertLessThanOrEqual(size.width, 380)
        XCTAssertEqual(size.height, WegaLayout.bandHeight)
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        let chips = try XCTUnwrap(text.range(of: "UpdateBandPhaseChips(steps: scan.steps)"))
        XCTAssertTrue(
            text[chips.upperBound...].prefix(200).contains(".environment(\\.colorScheme, .dark)"),
            "the chips' spinner resolves for the dark band in the light appearance"
        )
        let frame = try XCTUnwrap(
            text.range(of: ".frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)", range: chips.upperBound..<text.endIndex),
            "an elastic frame (0…∞) takes the column's width whatever the chips need"
        )
        XCTAssertLessThan(text.distance(from: chips.upperBound, to: frame.lowerBound), 200)
        XCTAssertTrue(text[frame.upperBound...].drop(while: \.isWhitespace).hasPrefix(".clipped()"),
                      "the chips are clipped to the column instead of widening it")
        XCTAssertTrue(text.contains("TimelineView(.periodic(from: .now, by: 1))"), "the elapsed time ticks once a second")
        let eyebrow = try XCTUnwrap(text.range(of: "scan.eyebrow(now: context.date)"))
        XCTAssertTrue(text[eyebrow.upperBound...].prefix(250).contains(".textCase(.uppercase)"))
        XCTAssertTrue(text[eyebrow.upperBound...].prefix(250).contains("monospaced: true"))
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
            ".accessibilityAddTraits(.isHeader)", "UpdateBandPhaseChips(steps: scan.steps)",
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
        let scanViews = try source("Sources/MacUpdater/UpdateBandScanViews.swift")
        let runViews = try source("Sources/MacUpdater/UpdateBandRunViews.swift")
        let summaryViews = try source("Sources/MacUpdater/UpdateBandSummaryViews.swift")
        for forbidden in [".glassEffect(", "Color.wegaToffee", "Color.wegaSuccess", "Color.wegaHoney"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
            XCTAssertFalse(scanViews.contains(forbidden), "UpdateBandScanViews.swift: \(forbidden)")
            XCTAssertFalse(runViews.contains(forbidden), "UpdateBandRunViews.swift: \(forbidden)")
            XCTAssertFalse(summaryViews.contains(forbidden), "UpdateBandSummaryViews.swift: \(forbidden)")
        }
        XCTAssertTrue(summaryViews.contains(".accessibilityLabel(tr(\"Wynik aktualizacji\"))"))
        XCTAssertTrue(summaryViews.contains(".help(summary.allCounts)") && summaryViews.contains(".accessibilityLabel(summary.allCounts)"),
                      "the compact counts truncate, so their tooltip and VoiceOver carry every count")
        XCTAssertFalse(summaryViews.contains(".animation("), "the result ring does not move")
        // The round element is the last thing in every layout, so VoiceOver reads the ring last.
        let lower = try XCTUnwrap(text.range(of: "private func content(")).upperBound
        let upper = try XCTUnwrap(text.range(of: "private func textColumn(")).lowerBound
        let switchBody = try XCTUnwrap(text[lower..<upper].components(separatedBy: "\n    }\n").first, "content's own body")
        let branches = switchBody.components(separatedBy: "case .").dropFirst()
        XCTAssertEqual(branches.count, 3)
        for branch in branches {
            let tail = try XCTUnwrap(branch.range(of: "roundElement(layout)"), "every layout ends in the round element")
            XCTAssertTrue(branch[tail.upperBound...].allSatisfy { $0.isWhitespace || $0 == "}" }, "nothing after the ring: \(branch)")
        }
        let round = try XCTUnwrap(text.range(of: "private func roundElement(")).upperBound
        XCTAssertTrue(text[round...].prefix(400).contains(
            "UpdateBandScanRing(completed: scan.completedSources, total: scan.totalSources, diameter: layout.buttonDiameter, showsWega: layout == .narrow)"
        ))
        XCTAssertTrue(text[round...].prefix(600).contains(
            "UpdateBandRunRing(completed: run.completed, total: run.total, diameter: layout.buttonDiameter, accessibilityValue: run.line)"
        ))
        XCTAssertTrue(scanViews.contains(".accessibilityLabel(tr(\"Postęp skanowania\"))"))
        XCTAssertTrue(runViews.contains(".accessibilityLabel(tr(\"Postęp aktualizacji\"))"))
    }

    /// UXP-13 — Wega sniffs during every scan, in every layout: her head in the regular and
    /// compact band, inside the ring in the narrow one, with motion only when it is allowed.
    func testWegaSniffsInEveryLayout() throws {
        let band = try source("Sources/MacUpdater/UpdateBand.swift")
        XCTAssertEqual(band.components(separatedBy: ".sniffing(scan != nil)").count, 3, "both band heads sniff")
        let views = try source("Sources/MacUpdater/UpdateBandScanViews.swift")
        let head = try XCTUnwrap(views.range(of: "WegaHead(pose: .sniff"), "the narrow ring draws Wega")
        XCTAssertTrue(views[head.upperBound...].prefix(200).contains(".accessibilityHidden(true)"))
        XCTAssertTrue(views[head.lowerBound...].prefix(200).contains(".sniffing(true)"))
        XCTAssertTrue(views.contains("if showsWega {"))
        XCTAssertTrue(views.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(views.contains("ContinuousMotion.forever("))
        XCTAssertFalse(views.contains(".repeatForever("))
        var rest = views.startIndex..<views.endIndex
        var spinners = 0
        while let spinner = views.range(of: "ProgressView()", range: rest) {
            let before = views[views.startIndex..<spinner.lowerBound].suffix(160)
            XCTAssertTrue(before.contains("reduceMotion"), "a spinner without a Reduce Motion branch (occurrence \(spinners + 1))")
            spinners += 1
            rest = spinner.upperBound..<views.endIndex
        }
        XCTAssertEqual(spinners, 1, "the running chip's spinner")
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        XCTAssertTrue(view.contains("WegaHead(pose: .sniff, size: 28).sniffing(true).accessibilityHidden(true)"),
                      "with no band, a small sniffing head stands next to the phase strip")
    }

    func testOnlyAVerifiedSourceWearsACheck() throws {
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        XCTAssertTrue(text.contains("chip.isVerified ? \"✓ \" + chip.token : chip.token"),
                      "a source that did not answer shows its bare token")
        XCTAssertEqual(text.components(separatedBy: "\"✓ \"").count, 2, "the check is drawn in one place only")
    }

    /// The band shows only when there is something to update, or while a run, its check or its
    /// summary is on screen (C2 stage 4: a run that empties the list keeps its band). A result
    /// that only waits for restarts keeps today's heading ("Wszystko aktualne"), while the list
    /// still shows it.
    func testTheBandShowsOnlyWithResults() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let lower = try XCTUnwrap(view.range(of: "private var resultsView: some View")).lowerBound
        let upper = try XCTUnwrap(view.range(of: "private var listHeader: some View")).lowerBound
        let results = view[lower..<upper]
        XCTAssertTrue(results.contains("if showsBand {"))
        XCTAssertTrue(results.contains("resultsBand"))
        XCTAssertFalse(results.contains("hasResults"), "restarts alone do not bring the band")
        let otherwise = try XCTUnwrap(results.range(of: "if !showsBand {"), "no band keeps today's heading")
        XCTAssertTrue(
            results[otherwise.upperBound...].drop(while: \.isWhitespace).hasPrefix("resultsHeading"),
            "the heading is the band's other branch"
        )
        XCTAssertTrue(view.contains("private var showsBand: Bool { hasUpdates || scan.updating || scan.runReport != nil }"),
                      "restarts alone still do not bring the band; a run and its summary do")
        XCTAssertTrue(view.contains("private var hasUpdates: Bool {\n        !(allItems.isEmpty && visibleManual.isEmpty)\n    }"))
        let column = try XCTUnwrap(view.range(of: "private var listColumn: some View")).lowerBound
        XCTAssertTrue(view[column...].prefix(200).contains("if !hasResults"))
        let detail = try source("Sources/MacUpdater/DetailColumn.swift")
        XCTAssertTrue(detail.contains("wegaLine: quip ?? wegaState.line"))
    }

    // MARK: - M3: the honesty note is never cut off

    /// The headline's text column in each layout, from the band's own `HStack`s: padding, the
    /// mascot, the summary column, the button and the spacings between them.
    private func headlineColumnWidth(bandWidth: CGFloat) -> CGFloat {
        switch UpdateBandLayout.style(forWidth: bandWidth) {
        case .narrow:
            return bandWidth - 2 * 16 - WegaLayout.bandButtonNarrowSize - 12
        case .compact:
            return bandWidth - 2 * 20 - WegaLayout.bandWegaCompactSize - WegaLayout.bandButtonCompactSize - 2 * 14
        case .regular:
            return bandWidth - 2 * 20 - WegaLayout.bandWegaSize - WegaLayout.bandSummaryWidth
                - WegaLayout.bandButtonSize - 3 * 20
        }
    }

    /// The band's three layouts at their narrowest: the minimum detail column (420 pt, which
    /// leaves the narrow band 388 pt) and the first widths at which compact and regular take over.
    private static let narrowestBandWidths: [CGFloat] = [
        420 - 2 * WegaLayout.listGutter, WegaLayout.bandNarrowBreakpoint, WegaLayout.bandCompactBreakpoint,
    ]

    /// The run is measured at those widths and at the band a 980 pt window leaves with the
    /// inspector open, 368 pt, where the narrow text column is 244 pt.
    private static let runBandWidths: [CGFloat] = [368] + narrowestBandWidths

    private func presentation(count: Int, note: String) -> UpdateBandPresentation {
        let base = fullPresentation
        return UpdateBandPresentation(
            totalCount: count, urgentCount: count, queueCount: 12,
            protectionText: tr("Sprawdzam możliwość cofnięcia"), lastCheck: base.lastCheck, freshness: base.freshness,
            sources: base.sources, wegaLine: base.wegaLine, incompleteNote: note, handOffCount: 10, catalogAgeMinutes: 30
        )
    }

    /// M3 — with both nuances present the headline used to end in the incomplete-check note,
    /// the first thing truncation cuts. Everything up to and including that note — the count
    /// and „skan niepełny”, plus the ellipsis truncation puts after it while the security
    /// part follows — must fit in the headline's line limit at each layout's narrowest width.
    /// Red before the reorder: the narrow Polish headline needed 65 pt of 43. Red before F1:
    /// compact and regular allowed one `.title` line (26 pt) and needed two (52 pt). The note is
    /// short („skan niepełny”) by the owner's decision: „sprawdzenie niepełne…” needed 235 pt of
    /// the compact band's 220 pt column at 480–494 pt.
    func testTheCountAndTheIncompleteNoteAreNeverTruncated() {
        for bandWidth in Self.narrowestBandWidths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            let font = Font.wega(layout.headlineStyle, weight: .semibold)
            let column = headlineColumnWidth(bandWidth: bandWidth)
            let lines = Array(repeating: "Ag", count: layout.headlineLineLimit).joined(separator: "\n")
            let allowed = NSHostingView(rootView: Text(verbatim: lines).font(font).frame(width: column)).fittingSize.height

            for language in [AppLanguage.pl, .en] {
                for count in [12, 22] {
                    let visible = withLanguage(language) {
                        let note = tr("skan niepełny")
                        let headline = presentation(count: count, note: note).headline
                        let end = headline.range(of: note)?.upperBound ?? headline.endIndex
                        return String(headline[..<end]) + (end < headline.endIndex ? "…" : "")
                    }
                    let needed = NSHostingView(rootView: Text(verbatim: visible).font(font)
                        .frame(width: column).fixedSize(horizontal: false, vertical: true)).fittingSize.height
                    XCTAssertLessThanOrEqual(
                        needed, allowed,
                        "M3: \(language), \(count), band \(bandWidth) pt (\(layout)): \"\(visible)\" needs \(needed) pt of \(allowed)"
                    )
                }
            }
        }
    }

    func testTheCatalogChipGivesWayBeforeTheCheckTime() throws {
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        let start = try XCTUnwrap(text.range(of: "private func eyebrow(")).upperBound
        let eyebrow = text[start...].prefix(700)
        XCTAssertEqual(eyebrow.components(separatedBy: "catalogChip").count - 1, 2, "only in the first two alternatives")
        XCTAssertTrue(eyebrow.contains("} else if layout == .narrow {\n            freshnessLabel"))
    }

    /// F1 — a two-line headline must still fit the band's fixed height. The frame always
    /// reports `bandHeight`, so this measures the content the frame holds: the longest copy
    /// (incomplete note, security part, a two-line Wega line, the plan link), idle and, with the
    /// vendor phase's headline, count and summary, scanning.
    func testTheTallestHeadlineStillFitsTheBand() {
        for bandWidth in Self.narrowestBandWidths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            for language in [AppLanguage.pl, .en] {
                for scan in [nil, scanFixture, scanNoteFixture] {
                    let height = withLanguage(language) {
                        let band = UpdateBand(
                            presentation: presentation(count: 22, note: tr("skan niepełny")),
                            scan: scan, planLinkEnabled: true, onShowPlan: {},
                            action: { layout in
                                Color.clear.frame(width: layout.buttonDiameter, height: layout.buttonDiameter)
                            }
                        )
                        return NSHostingView(rootView: band.naturalContent(width: bandWidth)).fittingSize.height
                    }
                    XCTAssertLessThanOrEqual(
                        height, WegaLayout.bandHeight,
                        "F1: \(language), band \(bandWidth) pt (\(layout)), scanning \(scan != nil): content is \(height) pt"
                    )
                }
            }
        }
    }

    /// UXP-13 — the scan's headline names the step; cut, it names none. Every caption must fit
    /// the headline's line limit at each layout's narrowest width.
    func testTheScanHeadlineIsNeverTruncated() {
        let captions: [(ScanProgress, Bool)] = [
            (.running(.brew), true), (.running(.brew), false), (.running(.mas), false),
            (.running(.npm), false), (.running(.manual), false),
        ]
        for bandWidth in Self.narrowestBandWidths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            let font = Font.wega(layout.headlineStyle, weight: .semibold)
            let column = headlineColumnWidth(bandWidth: bandWidth)
            let lines = Array(repeating: "Ag", count: layout.headlineLineLimit).joined(separator: "\n")
            let allowed = NSHostingView(rootView: Text(verbatim: lines).font(font).frame(width: column)).fittingSize.height
            for language in [AppLanguage.pl, .en] {
                for (progress, catalog) in captions {
                    let headline = withLanguage(language) { ScanPhaseCopy.caption(progress: progress, catalogRefreshing: catalog) }
                    let needed = NSHostingView(rootView: Text(verbatim: headline).font(font)
                        .frame(width: column).fixedSize(horizontal: false, vertical: true)).fittingSize.height
                    XCTAssertLessThanOrEqual(needed, allowed, "\(language), band \(bandWidth) pt (\(layout)): \"\(headline)\" needs \(needed) pt of \(allowed)")
                }
            }
        }
    }

    /// UXP-13 — the sentence under the scan's headline: why selecting waits, then the vendor
    /// count. Cut, the note stops explaining the inert list, so it must fit its line limit at
    /// each layout's narrowest width.
    func testTheScanLineIsNeverTruncated() throws {
        for bandWidth in Self.narrowestBandWidths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            let font = Font.wega(.callout)
            let column = headlineColumnWidth(bandWidth: bandWidth)
            let lines = Array(repeating: "Ag", count: layout.scanLineLimit).joined(separator: "\n")
            let allowed = NSHostingView(rootView: Text(verbatim: lines).font(font).frame(width: column)).fittingSize.height
            for language in [AppLanguage.pl, .en] {
                for scan in [scanNoteFixture, scanFixture] {
                    let line = withLanguage(language) { scan.line }
                    let needed = NSHostingView(rootView: Text(verbatim: line).font(font)
                        .frame(width: column).fixedSize(horizontal: false, vertical: true)).fittingSize.height
                    XCTAssertLessThanOrEqual(needed, allowed, "\(language), band \(bandWidth) pt (\(layout)): \"\(line)\" needs \(needed) pt of \(allowed)")
                }
            }
        }
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        XCTAssertTrue(text.contains(".lineLimit(scan == nil && run == nil ? (layout == .regular ? 2 : 1) : layout.scanLineLimit)"),
                      "the band draws the line at the limit measured here")
    }

    func testTheUndoLineIsNeverTheOneThatGetsDropped() throws {
        let text = try source("Sources/MacUpdater/UpdateBand.swift")
        let start = try XCTUnwrap(text.range(of: "var compactSummary: some View")).upperBound
        let end = try XCTUnwrap(text.range(of: "private var queueSummaryText: some View", range: start..<text.endIndex)).lowerBound
        let compact = text[start..<end]
        XCTAssertFalse(compact.contains("ViewThatFits"))
        // M9 — the undo line has a row of its own, shared with nothing it could yield its width to.
        XCTAssertFalse(compact.contains("HStack"))
        XCTAssertTrue(compact.contains("queueSummaryText\n            protection\n            planLink"))
        for bandWidth in Self.narrowestBandWidths {
            let column = UpdateBandLayout.style(forWidth: bandWidth) == .regular
                ? WegaLayout.bandSummaryWidth : headlineColumnWidth(bandWidth: bandWidth)
            for language in [AppLanguage.pl, .en] {
                for key in ["Sprawdzam możliwość cofnięcia", "Cofnięcie: %@ z %@"] {
                    let label = withLanguage(language) { key.contains("%@") ? trf(key, "22", "22") : tr(key) }
                    let width = NSHostingView(rootView: Label(label, systemImage: "shield.lefthalf.filled")
                        .font(.wega(.caption)).fixedSize()).fittingSize.width
                    XCTAssertLessThanOrEqual(width, column, "\(language) \(bandWidth) pt: \(label)")
                }
            }
        }
    }

    /// M9 — next to the longest undo line, "Pokaż, co dokładnie zrobię" was cut in the narrow
    /// and compact columns. Measured on the summary the band draws there, at its ideal width
    /// (a short queue line, which wraps by design otherwise): nothing in it needs more than the
    /// column, so neither the link nor the undo line is truncated.
    func testThePlanLinkIsNeverTruncated() {
        for bandWidth in Self.narrowestBandWidths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            let column = layout == .regular ? WegaLayout.bandSummaryWidth : headlineColumnWidth(bandWidth: bandWidth)
            for language in [AppLanguage.pl, .en] {
                for key in ["Sprawdzam możliwość cofnięcia", "Cofnięcie: %@ z %@"] {
                    let width = withLanguage(language) {
                        let protection = key.contains("%@") ? trf(key, "22", "22") : tr(key)
                        let band = UpdateBand(
                            presentation: UpdateBandPresentation(
                                totalCount: 22, urgentCount: 0, queueCount: 3, protectionText: protection,
                                lastCheck: nil, freshness: .fresh, sources: [], wegaLine: "Wega"
                            ),
                            scan: nil, planLinkEnabled: true, onShowPlan: {}, action: { _ in EmptyView() }
                        )
                        let summary = layout == .regular ? AnyView(band.summaryColumn) : AnyView(band.compactSummary)
                        return NSHostingView(rootView: summary.fixedSize()).fittingSize.width
                    }
                    XCTAssertLessThanOrEqual(width, column, "M9: \(language), band \(bandWidth) pt (\(layout)), \(key): needs \(width) pt")
                }
            }
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

// MARK: - C2 stage 4: the check and the summary

/// In an extension so the class body stays within `type_body_length`; the class's private
/// helpers (column widths, fixtures, `height(of:font:width:)`) are visible from the same file.
extension UpdateBandViewTests {
    /// The run's check with its longest copy: the vendor phase, a two-digit elapsed time.
    private var checkFixture: UpdateBandScanPresentation {
        UpdateBandScanPresentation(
            progress: .running(.manual), catalogRefreshing: false, startedAt: Date(timeIntervalSince1970: 0),
            manual: ManualScanProgress(checkedApps: 12, totalApps: 31), foundSoFar: 22, checksRunResult: true
        )
    }

    /// A summary with all six counts at two digits, the longest status („Aktualizacja
    /// niekompletna”), an incomplete check and a backup date. Built in the caller's language.
    private func summaryFixture(clean: Bool = false) -> UpdateBandSummaryPresentation {
        func items(_ prefix: String, _ count: Int, _ kind: OutdatedItem.Kind, _ verdict: ItemUpdateVerdict?)
            -> [(OutdatedItem, ItemUpdateVerdict?)] {
            (0..<count).map { index in
                let name = "\(prefix)-\(index)"
                return (OutdatedItem(key: UpdatePlanner.key(name: name, kind: kind), name: name, from: "1", to: "2", kind: kind), verdict)
            }
        }
        let planned = items("updated", 12, .cask, .succeeded) + (clean ? [] :
            items("failed", 10, .formula, .executionFailed) + items("rolled", 10, .cask, .rolledBack)
            + items("unconfirmed", 10, .npm, .notVerified) + items("idle", 10, .formula, nil))
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let report = UpdateRunReport.make(
            planned: planned.map(\.0),
            summary: UpdateRunSummary(
                items: planned.compactMap { item, verdict in
                    verdict.map { ItemUpdateOutcome(key: item.key, name: item.name, kind: item.kind, verdict: $0) }
                },
                diagnostics: [], needsSudoPassword: false
            ),
            startedAt: finishedAt.addingTimeInterval(-25 * 60), finishedAt: finishedAt,
            stillOutdatedKeys: [], confirmed: true
        )
        return UpdateBandSummaryPresentation(
            report: report, scanComplete: false,
            handOffCount: clean ? 0 : 10, undoExpiry: finishedAt.addingTimeInterval(7 * 86_400)
        )
    }

    private func eyebrowWidth(_ text: String) -> CGFloat {
        NSHostingView(rootView: Text(verbatim: text).font(.wega(.caption, weight: .semibold, monospaced: true))
            .tracking(0.8).textCase(.uppercase).fixedSize()).fittingSize.width
    }

    private func lineWidth(_ text: String, font: Font) -> CGFloat {
        NSHostingView(rootView: Text(verbatim: text).font(font).fixedSize()).fittingSize.width
    }

    /// The frame always reports the band's height, so this measures what the summary has to
    /// hold, at each layout's narrowest width and with the inspector open: the status and time
    /// range, the count with „skan niepełny”, Wega's line, all six counts (regular) or the
    /// compact counts, „Zamknij podsumowanie” and the result ring at the button's diameter.
    func testTheSummaryFitsTheBandAtEveryWidth() {
        for bandWidth in Self.runBandWidths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            let column = headlineColumnWidth(bandWidth: bandWidth)
            let summaryColumn = layout == .regular ? WegaLayout.bandSummaryWidth : column
            let headlineFont = Font.wega(layout.headlineStyle, weight: .semibold)
            let linkFont = Font.wega(.callout, weight: .semibold)
            let allowedHeadline = height(of: Array(repeating: "Ag", count: layout.headlineLineLimit).joined(separator: "\n"),
                                         font: headlineFont, width: column)
            for language in [AppLanguage.pl, .en] {
                withLanguage(language) {
                    let summary = summaryFixture()
                    let context = "\(language), band \(bandWidth) pt (\(layout))"
                    XCTAssertEqual(summary.report.status, .incomplete, context)
                    XCTAssertEqual(summary.countLines.count, 6, context)
                    let band = UpdateBand(
                        presentation: presentation(count: 22, note: tr("skan niepełny")), scan: nil, run: nil,
                        planLinkEnabled: true, onShowPlan: {}, summary: summary,
                        action: { layout in Color.clear.frame(width: layout.buttonDiameter, height: layout.buttonDiameter) }
                    )
                    let content = NSHostingView(rootView: band.naturalContent(width: bandWidth)).fittingSize.height
                    XCTAssertLessThanOrEqual(content, WegaLayout.bandHeight, "\(context): content is \(content) pt")

                    let ring = UpdateBandResultRing(updated: summary.updated, planned: summary.planned,
                                                    diameter: layout.buttonDiameter, accessibilityValue: summary.ringValue)
                    XCTAssertEqual(NSHostingView(rootView: ring).fittingSize,
                                   CGSize(width: layout.buttonDiameter, height: layout.buttonDiameter), context)

                    let close = tr("Zamknij podsumowanie")
                    let closeWidth = lineWidth(close, font: linkFont)
                    XCTAssertLessThanOrEqual(closeWidth, summaryColumn, "\(context): \"\(close)\" needs \(closeWidth) pt")
                    // The link-styled button draws the label on one line: with only updates the
                    // compact controls are the link alone, the regular ones one count and the link.
                    let clean = summaryFixture(clean: true)
                    let drawn = NSHostingView(rootView: UpdateBandSummaryControls(summary: clean, compact: layout != .regular, onClose: {})
                        .frame(width: summaryColumn).fixedSize(horizontal: false, vertical: true)).fittingSize.height
                    let oneLink = height(of: close, font: linkFont, width: summaryColumn)
                    let expected = layout == .regular ? oneLink + height(of: "Ag", font: .wega(.caption), width: summaryColumn) : oneLink
                    XCTAssertGreaterThanOrEqual(drawn, expected - 1, "\(context): the controls draw \(drawn) pt for \(expected) pt")
                    XCTAssertLessThanOrEqual(drawn, expected + 6, "\(context): the controls draw \(drawn) pt for \(expected) pt")

                    if layout == .regular {
                        for line in summary.countLines {
                            let width = lineWidth(line, font: .wega(.caption))
                            XCTAssertLessThanOrEqual(width, summaryColumn, "\(context): \"\(line)\" needs \(width) pt")
                        }
                    }
                    let visible = summary.headline
                    let neededHeadline = height(of: visible, font: headlineFont, width: column)
                    XCTAssertLessThanOrEqual(neededHeadline, allowedHeadline, "\(context): \"\(visible)\" needs \(neededHeadline) pt")
                    // Where the status and its time range do not fit, the status stands alone.
                    let status = eyebrowWidth(summary.shortEyebrow)
                    XCTAssertLessThanOrEqual(status, column, "\(context): \"\(summary.shortEyebrow)\" needs \(status) pt")
                }
            }
        }
    }

    /// The run's check is the scan state with its own words; it holds the band like the scan
    /// does, its elapsed time and headline are never cut, and its promise of a result fits.
    func testTheCheckFitsTheBandAtEveryWidth() {
        let captions: [(ScanProgress, Bool)] = [
            (.running(.brew), false), (.running(.mas), false), (.running(.npm), false), (.running(.manual), false),
        ]
        XCTAssertEqual(UpdateBandMode.resolve(scan: checkFixture, run: runFixture, summary: summaryFixture()), .scan(checkFixture),
                       "the band measured below draws the check, not the run it confirms")
        XCTAssertTrue(checkFixture.eyebrow(now: Date(timeIntervalSince1970: 725)).hasPrefix(tr("Sprawdzam wynik · %@").replacingOccurrences(of: "%@", with: "")))
        for bandWidth in Self.runBandWidths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            let column = headlineColumnWidth(bandWidth: bandWidth)
            let summaryColumn = layout == .regular ? WegaLayout.bandSummaryWidth : column
            let headlineFont = Font.wega(layout.headlineStyle, weight: .semibold)
            let allowedHeadline = height(of: Array(repeating: "Ag", count: layout.headlineLineLimit).joined(separator: "\n"),
                                         font: headlineFont, width: column)
            let allowedLine = height(of: Array(repeating: "Ag", count: layout.scanLineLimit).joined(separator: "\n"),
                                     font: .wega(.callout), width: column)
            for language in [AppLanguage.pl, .en] {
                withLanguage(language) {
                    let context = "\(language), band \(bandWidth) pt (\(layout))"
                    let band = UpdateBand(
                        presentation: presentation(count: 22, note: tr("skan niepełny")), scan: checkFixture, run: runFixture,
                        planLinkEnabled: false, onShowPlan: {}, summary: summaryFixture(),
                        action: { layout in Color.clear.frame(width: layout.buttonDiameter, height: layout.buttonDiameter) }
                    )
                    let content = NSHostingView(rootView: band.naturalContent(width: bandWidth)).fittingSize.height
                    XCTAssertLessThanOrEqual(content, WegaLayout.bandHeight, "\(context): content is \(content) pt")
                    let eyebrowText = checkFixture.eyebrow(now: Date(timeIntervalSince1970: 725))
                    let eyebrow = eyebrowWidth(eyebrowText)
                    XCTAssertLessThanOrEqual(eyebrow, column, "\(context): \"\(eyebrowText)\" needs \(eyebrow) pt")
                    let headline = height(of: checkFixture.headline, font: headlineFont, width: column)
                    XCTAssertLessThanOrEqual(headline, allowedHeadline, "\(context): \"\(checkFixture.headline)\"")
                    for (progress, catalog) in captions {
                        let line = UpdateBandScanPresentation(progress: progress, catalogRefreshing: catalog, startedAt: nil,
                                                              manual: nil, foundSoFar: 0, checksRunResult: true).line
                        let needed = height(of: line, font: .wega(.callout), width: column)
                        XCTAssertLessThanOrEqual(needed, allowedLine, "\(context): \"\(line)\" needs \(needed) pt")
                    }
                    // The promise may take two lines wherever the band draws it.
                    let promiseFont = Font.wega(.callout, weight: .semibold)
                    let promise = height(of: checkFixture.summary, font: promiseFont, width: summaryColumn)
                    let allowedPromise = height(of: "Ag\nAg", font: promiseFont, width: summaryColumn)
                    XCTAssertLessThanOrEqual(promise, allowedPromise, "\(context): \"\(checkFixture.summary)\" needs \(promise) pt")
                }
            }
        }
    }
}
