import SwiftUI
import MacUpdaterCore

/// How the band lays itself out, decided from the band's own width (what its `GeometryReader`
/// sees), not the window's.
enum UpdateBandLayout {
    case regular, compact, narrow

    static func style(forWidth width: CGFloat) -> UpdateBandLayout {
        if width < WegaLayout.bandNarrowBreakpoint { return .narrow }
        return width < WegaLayout.bandCompactBreakpoint ? .compact : .regular
    }

    /// The headline's text style in this layout.
    var headlineStyle: WegaTextStyle { self == .narrow ? .title2 : .title }

    /// How many lines the headline may take before it truncates. Two in every layout: one
    /// `.title` line cut "N aktualizacji · skan niepełny" at the compact and regular
    /// layouts' narrowest widths. Two still fit the band's fixed height (at most 167 of 188 pt,
    /// compact and refreshing); three would not (193 pt).
    var headlineLineLimit: Int { 2 }

    /// How many lines the sentence under the headline may take while a scan or an update runs.
    /// Two in every layout: one cut „Zaznaczanie wróci, gdy skan się skończy.” in the compact
    /// band's 220 pt column, and a long cask's stage („Instaluję com.microsoft.edgemac — 12 z 40”)
    /// as well. Neither state has the queue summary, so the second line still fits the band.
    var scanLineLimit: Int { 2 }

    /// The round button's diameter in this layout.
    var buttonDiameter: CGFloat {
        switch self {
        case .regular: WegaLayout.bandButtonSize
        case .compact: WegaLayout.bandButtonCompactSize
        case .narrow:  WegaLayout.bandButtonNarrowSize
        }
    }
}

/// C2 stage 4 — the one state the band describes. Every slot (eyebrow, headline, sentence,
/// summary, round element) reads this, so no slot can mix the words of two states.
enum UpdateBandMode: Equatable {
    case scan(UpdateBandScanPresentation)
    case run(UpdateBandRunPresentation)
    case summary(UpdateBandSummaryPresentation)
    case results
    /// The scan left nothing to update (owner, 2026-11-22): the band stays and says so.
    case upToDate

    /// The precedence: a scan (the run's check included) over the run it confirms, the run over
    /// a summary still open from the previous run, the summary over the results, which say the
    /// Mac is up to date when `upToDate`.
    static func resolve(scan: UpdateBandScanPresentation?, run: UpdateBandRunPresentation?,
                        summary: UpdateBandSummaryPresentation?, upToDate: Bool = false) -> UpdateBandMode {
        if let scan { return .scan(scan) }
        if let run { return .run(run) }
        if let summary { return .summary(summary) }
        return upToDate ? .upToDate : .results
    }

    /// Whether the band has a summary to show beside the headline. With nothing to update there
    /// is no queue, no undo coverage and no plan to show.
    var showsSummary: Bool { self != .upToDate }

    /// How many lines the headline may take. Without a summary the compact band has no row under
    /// the sentence, so the headline takes that room: „I can't tell whether everything is up to
    /// date” needs four lines of the compact band's narrowest column (166 pt).
    func headlineLineLimit(in layout: UpdateBandLayout) -> Int {
        showsSummary ? layout.headlineLineLimit : 4
    }

    func headline(results: UpdateBandPresentation) -> String {
        switch self {
        case .scan(let scan):       scan.headline
        case .run(let run):         run.headline
        case .summary(let summary): summary.headline
        case .results:              results.headline
        case .upToDate:             results.upToDateHeadline
        }
    }

    func line(results: UpdateBandPresentation) -> String {
        switch self {
        case .scan(let scan):       scan.line
        case .run(let run):         run.line
        case .summary(let summary): summary.line
        case .results, .upToDate:   results.line
        }
    }

    /// The eyebrow of a state whose time does not move (since when the run started, when the
    /// summarised run ran); `nil` for the scan's ticking eyebrow and the results' freshness.
    var fixedEyebrow: String? {
        switch self {
        case .run(let run):         run.eyebrow
        case .summary(let summary): summary.eyebrow
        case .scan, .results, .upToDate: nil
        }
    }

    /// What the fixed eyebrow gives way to where it does not fit: the summary's status without
    /// its time range („Aktualizacja niekompletna · 8:35–9:00” needs 259 pt of a 220 pt column).
    var shortEyebrow: String? {
        if case .summary(let summary) = self { return summary.shortEyebrow }
        return nil
    }
}

/// The dark band above the Updates list: Wega, what was found, what is queued and the round
/// update button. Always `WegaLayout.bandHeight` tall so the list below never moves; text
/// truncates before the band grows. The caller builds the button, so its gate stays with the
/// update path, and says whether the plan link may open (`planLinkEnabled`).
///
/// UXP-13 — while a scan runs in place the caller passes `scan`: the band then reports the scan
/// (elapsed time and phase chips, the phase, the vendor count, what was found so far) and the
/// ring stands where the button was, with Wega sniffing.
///
/// C2 stage 3 — while an update runs the caller passes `run`: the band reports the run (since
/// when, the stage, the counter) and carries its stop and „Pokaż log”, and a ring of finished
/// packages stands where the button was. Wega stays still. The band sits outside the disabled
/// screen, so the stop stays live while the rows are locked.
///
/// C2 stage 4 — after the run the caller passes `summary` until the user closes it: the band
/// then says how the run ended, counts each result and offers „Zamknij podsumowanie”, and a
/// result ring stands where the button was. The run's check is a scan (`scan` wins over `run`).
///
/// Owner, 2026-11-22 — when the scan leaves nothing to update the band stays: Wega asleep, „Wszystko
/// aktualne”, the check time and sources, the scan button, and a check mark where the update
/// button was (`UpdateBandPresentation.nothingToUpdate`). It used to give way to a plain heading,
/// so on an up-to-date Mac it came and went with every scan.
struct UpdateBand<Action: View>: View {
    let presentation: UpdateBandPresentation
    let scan: UpdateBandScanPresentation?
    let run: UpdateBandRunPresentation?
    let planLinkEnabled: Bool
    let onShowPlan: () -> Void
    let onStop: () -> Void
    let onShowLog: () -> Void
    let summary: UpdateBandSummaryPresentation?
    let onCloseSummary: () -> Void
    /// The round scan button, beside the big circle (owner, 2026-11-22, option B).
    let scanButton: ScanRoundButton
    let action: (UpdateBandLayout) -> Action

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        presentation: UpdateBandPresentation,
        scan: UpdateBandScanPresentation?,
        run: UpdateBandRunPresentation? = nil,
        planLinkEnabled: Bool,
        onShowPlan: @escaping () -> Void,
        onStop: @escaping () -> Void = {},
        onShowLog: @escaping () -> Void = {},
        summary: UpdateBandSummaryPresentation? = nil,
        onCloseSummary: @escaping () -> Void = {},
        scanButton: ScanRoundButton = ScanRoundButton(state: .start(enabled: true), style: .band, onStart: {}, onCancel: {}),
        @ViewBuilder action: @escaping (UpdateBandLayout) -> Action
    ) {
        self.presentation = presentation
        self.scan = scan
        self.run = run
        self.planLinkEnabled = planLinkEnabled
        self.onShowPlan = onShowPlan
        self.onStop = onStop
        self.onShowLog = onShowLog
        self.summary = summary
        self.onCloseSummary = onCloseSummary
        self.scanButton = scanButton
        self.action = action
    }

    var body: some View {
        GeometryReader { proxy in
            naturalContent(width: proxy.size.width)
                .frame(height: WegaLayout.bandHeight)
                .foregroundStyle(Color.wegaBandText)
                .background { backdrop }
                .overlay {
                    RoundedRectangle(cornerRadius: WegaLayout.bandRadius, style: .continuous)
                        .strokeBorder(Color.wegaBandBorder, lineWidth: colorScheme == .dark ? 1.5 : 2)
                }
        }
        .frame(height: WegaLayout.bandHeight)
        .accessibilityElement(children: .contain)
    }

    /// The band's content at its own height for a band `width` wide: what the fixed
    /// `WegaLayout.bandHeight` frame has to hold. The body draws exactly this inside that frame,
    /// and the layout tests measure it, because the frame alone always reports the fixed height.
    func naturalContent(width: CGFloat) -> some View {
        let layout = UpdateBandLayout.style(forWidth: width)
        return content(layout)
            .padding(.horizontal, layout == .narrow ? 16 : 20)
            .frame(width: width)
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ layout: UpdateBandLayout) -> some View {
        switch layout {
        case .regular:
            HStack(spacing: 20) {
                WegaHead(pose: wegaPose, size: WegaLayout.bandWegaSize)
                    .sniffing(scan != nil)
                    .accessibilityHidden(true)
                textColumn(layout)
                if mode.showsSummary {
                    regularSummary
                        .frame(width: WegaLayout.bandSummaryWidth, alignment: .leading)
                }
                scanButton
                roundElement(layout)
            }
        case .compact:
            HStack(spacing: 14) {
                WegaHead(pose: wegaPose, size: WegaLayout.bandWegaCompactSize)
                    .sniffing(scan != nil)
                    .accessibilityHidden(true)
                textColumn(layout)
                scanButton
                roundElement(layout)
            }
        case .narrow:
            HStack(spacing: 12) {
                textColumn(layout)
                VStack(spacing: 8) {
                    scanButton
                    roundElement(layout)
                }
            }
        }
    }

    private var mode: UpdateBandMode { .resolve(scan: scan, run: run, summary: summary, upToDate: presentation.nothingToUpdate) }

    private var wegaPose: WegaPose {
        switch mode {
        case .scan:     .sniff
        case .upToDate: presentation.incompleteNote == nil ? .sleep : .sad
        default:        .idle
        }
    }

    /// The update button, or the ring that counts a scan's sources, a run's packages or the
    /// summarised run's result. Last in every layout, so VoiceOver reads it last.
    @ViewBuilder
    private func roundElement(_ layout: UpdateBandLayout) -> some View {
        switch mode {
        case .scan(let scan):
            UpdateBandScanRing(completed: scan.completedSources, total: scan.totalSources, diameter: layout.buttonDiameter, showsWega: layout == .narrow)
        case .run(let run):
            UpdateBandRunRing(completed: run.completed, total: run.total, diameter: layout.buttonDiameter, accessibilityValue: run.line)
        case .summary(let summary):
            UpdateBandResultRing(updated: summary.updated, planned: summary.planned, diameter: layout.buttonDiameter, accessibilityValue: summary.ringValue)
        case .results:
            action(layout)
        case .upToDate:
            UpdateBandUpToDateMark(complete: presentation.incompleteNote == nil, diameter: layout.buttonDiameter)
        }
    }

    private func textColumn(_ layout: UpdateBandLayout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            eyebrow(layout)
            Text(mode.headline(results: presentation))
                .font(.wega(layout.headlineStyle, weight: .semibold))
                .foregroundStyle(Color.wegaBandText)
                .lineLimit(mode.headlineLineLimit(in: layout))
                .accessibilityAddTraits(.isHeader)
            Text(mode.line(results: presentation))
                .font(.wega(.callout))
                .foregroundStyle(Color.wegaBandSecondaryText)
                .lineLimit(scan == nil && run == nil ? (layout == .regular ? 2 : 1) : layout.scanLineLimit)
            if layout != .regular {
                compactRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The compact and narrow layouts' row under the sentence: what the regular layout's
    /// summary column says, in the text column.
    @ViewBuilder
    private var compactRow: some View {
        switch mode {
        case .scan(let scan):
            scanSummary(scan)
        case .run(let run):
            UpdateBandRunControls(run: run, showsNote: false, onStop: onStop, onShowLog: onShowLog)
        case .summary(let summary):
            UpdateBandSummaryControls(summary: summary, compact: true, onClose: onCloseSummary)
        case .results:
            compactSummary
        case .upToDate:
            EmptyView()
        }
    }

    @ViewBuilder
    private func eyebrow(_ layout: UpdateBandLayout) -> some View {
        if case .scan(let scan) = mode {
            scanEyebrow(scan)
        } else if let fixed = mode.fixedEyebrow {
            fixedEyebrow(fixed, shortened: mode.shortEyebrow)
        } else if layout == .narrow {
            freshnessLabel
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    freshnessLabel
                    catalogChip
                    sourceChips
                }
                HStack(spacing: 8) {
                    freshnessLabel
                    catalogChip
                }
                freshnessLabel
            }
        }
    }

    @ViewBuilder
    private var freshnessLabel: some View {
        if let text = presentation.freshnessText {
            Text(text)
                .font(.wega(.caption, weight: .semibold, monospaced: true))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(presentation.freshnessIsExplicit ? Color.wegaBandAccentText : Color.wegaBandSecondaryText)
                .lineLimit(1)
        }
    }

    /// UXP-14 — says the scan kept Homebrew's catalog instead of refreshing it, and how old it is.
    @ViewBuilder
    private var catalogChip: some View {
        if let note = presentation.catalogNote {
            Text(note)
                .font(.wega(.caption2, weight: .semibold, monospaced: true))
                .foregroundStyle(Color.wegaBandSecondaryText)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.wegaBandText.opacity(0.08)))
                .help(note)
        }
    }

    private var sourceChips: some View {
        HStack(spacing: 4) {
            ForEach(presentation.sourceChips, id: \.token) { chip in
                Text(chip.isVerified ? "✓ " + chip.token : chip.token)
                    .font(.wega(.caption2, weight: .semibold, monospaced: true))
                    .foregroundStyle(Color.wegaBandSecondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.wegaBandText.opacity(0.08)))
            }
        }
    }

    /// The patrol's elapsed time, ticking once a second, then the phase chips. The time keeps
    /// its width; the chips are clipped to the column instead of widening it.
    private func scanEyebrow(_ scan: UpdateBandScanPresentation) -> some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(scan.eyebrow(now: context.date))
                    .font(.wega(.caption, weight: .semibold, monospaced: true))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.wegaBandAccentText)
                    .lineLimit(1)
                    .fixedSize()
            }
            UpdateBandPhaseChips(steps: scan.steps)
                .fixedSize()
                .environment(\.colorScheme, .dark)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// When the run started, or when the summarised run ran. The time does not move, so
    /// nothing ticks under it. Where the text does not fit, its `shortened` form stands instead.
    @ViewBuilder
    private func fixedEyebrow(_ text: String, shortened: String?) -> some View {
        if let shortened {
            ViewThatFits(in: .horizontal) {
                fixedEyebrowText(text)
                fixedEyebrowText(shortened)
            }
        } else {
            fixedEyebrowText(text)
        }
    }

    private func fixedEyebrowText(_ text: String) -> some View {
        Text(text)
            .font(.wega(.caption, weight: .semibold, monospaced: true))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Color.wegaBandAccentText)
            .lineLimit(1)
    }

    // MARK: Summary

    @ViewBuilder
    private var regularSummary: some View {
        switch mode {
        case .scan(let scan):
            scanSummary(scan)
        case .run(let run):
            UpdateBandRunControls(run: run, showsNote: true, onStop: onStop, onShowLog: onShowLog)
        case .summary(let summary):
            UpdateBandSummaryControls(summary: summary, compact: false, onClose: onCloseSummary)
        case .results:
            summaryColumn
        case .upToDate:
            EmptyView()
        }
    }

    /// While a scan runs the summary says only what it has found so far; during the run's check,
    /// that the result follows the check. Two lines: "I'll show the result after the check."
    /// needs 205 pt of the regular column's 190 pt, and no scan state is short of height.
    private func scanSummary(_ scan: UpdateBandScanPresentation) -> some View {
        Text(scan.summary)
            .font(.wega(.callout, weight: .semibold))
            .foregroundStyle(Color.wegaBandText)
            .lineLimit(2)
    }

    /// The regular layout's summary. Internal, like `compactSummary`, so the layout tests can
    /// measure what the band draws.
    var summaryColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            queueSummaryText
            protection
            planLink
        }
    }

    /// The narrow and compact layouts' summary: the queue, the undo coverage and the plan link,
    /// one row each. Side by side, the link was cut next to the longer undo line (M9).
    var compactSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            queueSummaryText
            protection
            planLink
        }
    }

    private var queueSummaryText: some View {
        Text(presentation.queueSummary)
            .font(.wega(.callout, weight: .semibold))
            .foregroundStyle(Color.wegaBandText)
            .lineLimit(2)
    }

    @ViewBuilder
    private var protection: some View {
        if let text = presentation.protectionText {
            Label(text, systemImage: "shield.lefthalf.filled")
                .font(.wega(.caption))
                .foregroundStyle(Color.wegaBandSecondaryText)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var planLink: some View {
        if presentation.showsPlanLink {
            Button(tr("Pokaż, co dokładnie zrobię"), action: onShowPlan)
                .buttonStyle(.link)
                .font(.wega(.callout, weight: .semibold))
                .foregroundStyle(planLinkEnabled ? Color.wegaBandAccentText : Color.wegaBandSecondaryText.opacity(0.5))
                .lineLimit(1)
                .disabled(!planLinkEnabled)
        }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [.wegaBandStart, .wegaBandMid, .wegaBandEnd],
                startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1)
            )
            if contrast != .increased {
                glow(Color(nsColor: WegaPalette.lavender.dark.nsColor), center: UnitPoint(x: 0.1, y: 0.9))
                glow(Color(nsColor: WegaPalette.honey.dark.nsColor), center: UnitPoint(x: 0.96, y: 1.1))
            }
            ScanCodeBackdrop(isScanning: scan != nil, color: .wegaBandAccentText)
        }
        .clipShape(RoundedRectangle(cornerRadius: WegaLayout.bandRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, center: UnitPoint) -> some View {
        RadialGradient(
            colors: [color.opacity(0.45), color.opacity(0)],
            center: center, startRadius: 0, endRadius: 130
        )
    }
}
