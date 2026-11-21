import SwiftUI
import MacUpdaterCore

/// C2 stage 3 — the round element while an update runs: the packages finished out of the
/// batch, at exactly the button's diameter so nothing beside it moves when a run starts or ends.
/// The ring is the run's only progress; there is no linear bar. Wega stands still next to it —
/// she sniffs only while a scan runs.
struct UpdateBandRunRing: View {
    let completed: Int
    let total: Int
    let diameter: CGFloat
    /// What VoiceOver hears: the stage, which already ends with the counter.
    let accessibilityValue: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: CGFloat { total > 0 ? CGFloat(completed) / CGFloat(total) : 0 }
    private var lineWidth: CGFloat { max(4, diameter * 0.07) }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.wegaBandText.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(Color.wegaBandAccentText, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
            // A three-digit batch shrinks to stay inside the track instead of running over it.
            Text(verbatim: "\(completed)/\(total)")
                .font(.wega(.title2, weight: .semibold, monospaced: true))
                .foregroundStyle(Color.wegaBandText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 2 * lineWidth)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Postęp aktualizacji"))
        .accessibilityValue(accessibilityValue)
    }
}

/// C2 stage 3 — the band's summary while an update runs. In the regular layout it starts with
/// the counter and the promise that no install is cut in half; in every layout it carries the
/// stop and, while the log under the list is closed, „Pokaż log”.
///
/// The stop asks for REL-12's cooperative stop at the next package boundary, the only safe place
/// to stop; ⌘. asks for the same one. A stop already requested cannot be requested twice.
struct UpdateBandRunControls: View {
    let run: UpdateBandRunPresentation
    /// Regular layout: the counter and the note have the summary column to themselves.
    let showsNote: Bool
    let onStop: () -> Void
    let onShowLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsNote {
                if let counter = run.counter {
                    Text(counter)
                        .font(.wega(.callout, weight: .semibold))
                        .foregroundStyle(Color.wegaBandText)
                        .lineLimit(1)
                }
                Text(tr("Bieżącej instalacji nie przerywam w połowie."))
                    .font(.wega(.caption))
                    .foregroundStyle(Color.wegaBandSecondaryText)
                    .lineLimit(2)
            }
            Button(run.stopLabel, action: onStop)
                .buttonStyle(.link)
                .font(.wega(.callout, weight: .semibold))
                // Requested, the label is the run's state, so it stays readable rather than dimmed.
                .foregroundStyle(run.isStopping ? Color.wegaBandSecondaryText : Color.wegaBandAccentText)
                .lineLimit(2)
                .disabled(run.isStopping)
                .help(UpdateRunCopy.stopHelp)
            if !run.logShown {
                Button(tr("Pokaż log"), action: onShowLog)
                    .buttonStyle(.link)
                    .font(.wega(.callout, weight: .semibold))
                    .foregroundStyle(Color.wegaBandAccentText)
                    .lineLimit(1)
            }
        }
    }
}
