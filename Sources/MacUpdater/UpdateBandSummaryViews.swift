import SwiftUI
import MacUpdaterCore

/// C2 stage 4 — the round element once a run has been checked: the updated share of the
/// planned items in success green, the rest in danger coral, at exactly the button's diameter
/// so nothing beside it moves when the summary opens or closes. The band is always dark, so
/// both colours are the palette's dark values, like the glows. It does not move.
struct UpdateBandResultRing: View {
    let updated: Int
    let planned: Int
    let diameter: CGFloat
    /// What VoiceOver hears: "Zaktualizowano 4 z 5".
    let accessibilityValue: String

    private static let updatedColor = Color(nsColor: WegaPalette.success.dark.nsColor)
    private static let restColor = Color(nsColor: WegaPalette.danger.dark.nsColor)

    private var lineWidth: CGFloat { max(4, diameter * 0.07) }
    private var updatedShare: CGFloat {
        planned > 0 ? CGFloat(min(max(updated, 0), planned)) / CGFloat(planned) : 0
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.wegaBandText.opacity(0.16), lineWidth: lineWidth)
            if updatedShare > 0 {
                arc(from: 0, to: updatedShare, color: Self.updatedColor)
            }
            if planned > 0, updatedShare < 1 {
                arc(from: updatedShare, to: 1, color: Self.restColor)
            }
            Text(verbatim: "\(updated)/\(planned)")
                .font(.wega(.title2, weight: .semibold, monospaced: true))
                .foregroundStyle(Color.wegaBandText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 2 * lineWidth)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Wynik aktualizacji"))
        .accessibilityValue(accessibilityValue)
    }

    /// Butt caps, so the two shares meet without overlapping or leaving a gap.
    private func arc(from start: CGFloat, to end: CGFloat, color: Color) -> some View {
        Circle()
            .inset(by: lineWidth / 2)
            .trim(from: start, to: end)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            .rotationEffect(.degrees(-90))
    }
}

/// C2 stage 4 — the band's summary once a run has been checked, and its one door back to the
/// list. Regular: one line per non-zero count, then „Zamknij podsumowanie”. Compact and
/// narrow: the counts other than "Zaktualizowano" (the headline says it) in at most two lines,
/// then the link; truncated, every count is still in the tooltip and in what VoiceOver reads.
struct UpdateBandSummaryControls: View {
    let summary: UpdateBandSummaryPresentation
    let compact: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            if compact {
                if !summary.compactCounts.isEmpty {
                    Text(summary.compactCounts)
                        .font(.wega(.callout, weight: .semibold))
                        .foregroundStyle(Color.wegaBandText)
                        .lineLimit(2)
                        .help(summary.allCounts)
                        .accessibilityLabel(summary.allCounts)
                }
            } else {
                ForEach(summary.countLines, id: \.self) { line in
                    Text(line)
                        .font(.wega(.caption))
                        .foregroundStyle(Color.wegaBandText)
                        .lineLimit(1)
                }
            }
            Button(tr("Zamknij podsumowanie"), action: onClose)
                .buttonStyle(.link)
                .font(.wega(.callout, weight: .semibold))
                .foregroundStyle(Color.wegaBandAccentText)
                .lineLimit(1)
        }
    }
}
