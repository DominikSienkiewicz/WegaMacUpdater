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
    /// `.title` line cut "N aktualizacji · sprawdzenie niepełne" at the compact and regular
    /// layouts' narrowest widths. Two still fit the band's fixed height (at most 167 of 188 pt,
    /// compact and refreshing); three would not (193 pt).
    var headlineLineLimit: Int { 2 }

    /// How many lines the sentence under the headline may take while a scan runs. Two in every
    /// layout: one cut „Zaznaczanie wróci, gdy skan się skończy.” in the compact band's 220 pt
    /// column. The scan state has no queue summary, so the second line still fits the band.
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

/// The dark band above the Updates list: Wega, what was found, what is queued and the round
/// update button. Always `WegaLayout.bandHeight` tall so the list below never moves; text
/// truncates before the band grows. The caller builds the button, so its gate stays with the
/// update path, and says whether the plan link may open (`planLinkEnabled`).
///
/// UXP-13 — while a scan runs in place the caller passes `scan`: the band then reports the scan
/// (elapsed time and phase chips, the phase, the vendor count, what was found so far) and the
/// ring stands where the button was, with Wega sniffing.
struct UpdateBand<Action: View>: View {
    let presentation: UpdateBandPresentation
    let scan: UpdateBandScanPresentation?
    let planLinkEnabled: Bool
    let onShowPlan: () -> Void
    let action: (UpdateBandLayout) -> Action

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        presentation: UpdateBandPresentation,
        scan: UpdateBandScanPresentation?,
        planLinkEnabled: Bool,
        onShowPlan: @escaping () -> Void,
        @ViewBuilder action: @escaping (UpdateBandLayout) -> Action
    ) {
        self.presentation = presentation
        self.scan = scan
        self.planLinkEnabled = planLinkEnabled
        self.onShowPlan = onShowPlan
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
                regularSummary
                    .frame(width: WegaLayout.bandSummaryWidth, alignment: .leading)
                roundElement(layout)
            }
        case .compact:
            HStack(spacing: 14) {
                WegaHead(pose: wegaPose, size: WegaLayout.bandWegaCompactSize)
                    .sniffing(scan != nil)
                    .accessibilityHidden(true)
                textColumn(layout)
                roundElement(layout)
            }
        case .narrow:
            HStack(spacing: 12) {
                textColumn(layout)
                roundElement(layout)
            }
        }
    }

    private var wegaPose: WegaPose { scan == nil ? .idle : .sniff }

    /// The update button, or while a scan runs the ring that counts its sources. Last in every
    /// layout, so VoiceOver reads it last.
    @ViewBuilder
    private func roundElement(_ layout: UpdateBandLayout) -> some View {
        if let scan {
            UpdateBandScanRing(completed: scan.completedSources, total: scan.totalSources, diameter: layout.buttonDiameter, showsWega: layout == .narrow)
        } else {
            action(layout)
        }
    }

    private func textColumn(_ layout: UpdateBandLayout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            eyebrow(layout)
            Text(scan?.headline ?? presentation.headline)
                .font(.wega(layout.headlineStyle, weight: .semibold))
                .foregroundStyle(Color.wegaBandText)
                .lineLimit(layout.headlineLineLimit)
                .accessibilityAddTraits(.isHeader)
            Text(scan?.line ?? presentation.line)
                .font(.wega(.callout))
                .foregroundStyle(Color.wegaBandSecondaryText)
                .lineLimit(scan == nil ? (layout == .regular ? 2 : 1) : layout.scanLineLimit)
            if layout != .regular {
                if let scan {
                    scanSummary(scan)
                } else {
                    compactSummary
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func eyebrow(_ layout: UpdateBandLayout) -> some View {
        if let scan {
            scanEyebrow(scan)
        } else if layout == .narrow {
            freshnessLabel
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    freshnessLabel
                    sourceChips
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

    // MARK: Summary

    @ViewBuilder
    private var regularSummary: some View {
        if let scan {
            scanSummary(scan)
        } else {
            summaryColumn
        }
    }

    /// While a scan runs the summary says only what it has found so far.
    private func scanSummary(_ scan: UpdateBandScanPresentation) -> some View {
        Text(scan.summary)
            .font(.wega(.callout, weight: .semibold))
            .foregroundStyle(Color.wegaBandText)
            .lineLimit(1)
    }

    private var summaryColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            queueSummaryText
            protection
            planLink
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            queueSummaryText
            HStack(spacing: 8) {
                protection.layoutPriority(1)
                planLink
            }
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
                .buttonStyle(.plain)
                .font(.wega(.caption, weight: .semibold))
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
