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
/// update path.
struct UpdateBand<Action: View>: View {
    let presentation: UpdateBandPresentation
    let refreshProgress: ScanProgress?
    let onShowPlan: () -> Void
    let action: (UpdateBandLayout) -> Action

    @Environment(\.colorScheme) private var colorScheme

    init(
        presentation: UpdateBandPresentation,
        refreshProgress: ScanProgress?,
        onShowPlan: @escaping () -> Void,
        @ViewBuilder action: @escaping (UpdateBandLayout) -> Action
    ) {
        self.presentation = presentation
        self.refreshProgress = refreshProgress
        self.onShowPlan = onShowPlan
        self.action = action
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = UpdateBandLayout.style(forWidth: proxy.size.width)
            content(layout)
                .padding(.horizontal, layout == .narrow ? 16 : 20)
                .frame(width: proxy.size.width, height: WegaLayout.bandHeight)
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

    // MARK: Layout

    @ViewBuilder
    private func content(_ layout: UpdateBandLayout) -> some View {
        switch layout {
        case .regular:
            HStack(spacing: 20) {
                WegaHead(pose: .idle, size: WegaLayout.bandWegaSize)
                    .accessibilityHidden(true)
                textColumn(layout)
                summaryColumn
                    .frame(width: WegaLayout.bandSummaryWidth, alignment: .leading)
                action(layout)
            }
        case .compact:
            HStack(spacing: 14) {
                WegaHead(pose: .idle, size: WegaLayout.bandWegaCompactSize)
                    .accessibilityHidden(true)
                textColumn(layout)
                action(layout)
            }
        case .narrow:
            HStack(spacing: 12) {
                textColumn(layout)
                action(layout)
            }
        }
    }

    private func textColumn(_ layout: UpdateBandLayout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            eyebrow(layout)
            Text(presentation.headline)
                .font(.wega(layout == .narrow ? .title2 : .title, weight: .semibold))
                .foregroundStyle(Color.wegaBandText)
                .lineLimit(layout == .narrow ? 2 : 1)
                .accessibilityAddTraits(.isHeader)
            Text(presentation.line)
                .font(.wega(.callout))
                .foregroundStyle(Color.wegaBandSecondaryText)
                .lineLimit(layout == .regular ? 2 : 1)
            if layout != .regular {
                compactSummary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func eyebrow(_ layout: UpdateBandLayout) -> some View {
        if refreshProgress != nil {
            ScanPhaseStrip(progress: refreshProgress)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
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

    // MARK: Summary

    private var summaryColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.queueSummary)
                .font(.wega(.callout, weight: .semibold))
                .foregroundStyle(Color.wegaBandText)
                .lineLimit(1)
            protection
            planLink
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    queueSummaryText
                    protection
                }
                queueSummaryText
            }
            planLink
        }
    }

    private var queueSummaryText: some View {
        Text(presentation.queueSummary)
            .font(.wega(.callout, weight: .semibold))
            .foregroundStyle(Color.wegaBandText)
            .lineLimit(1)
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
                .foregroundStyle(Color.wegaBandAccentText)
                .lineLimit(1)
        }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [.wegaBandStart, .wegaBandMid, .wegaBandEnd],
                startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1)
            )
            glow(Color(nsColor: WegaPalette.lavender.dark.nsColor), center: UnitPoint(x: 0.1, y: 0.9))
            glow(Color(nsColor: WegaPalette.honey.dark.nsColor), center: UnitPoint(x: 0.96, y: 1.1))
        }
        .clipShape(RoundedRectangle(cornerRadius: WegaLayout.bandRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, center: UnitPoint) -> some View {
        RadialGradient(
            colors: [color.opacity(0.6), color.opacity(0)],
            center: center, startRadius: 0, endRadius: 130
        )
    }
}
