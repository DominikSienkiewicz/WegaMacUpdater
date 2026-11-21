import SwiftUI
import MacUpdaterCore

/// UXP-13 — the band's eyebrow chips while a scan runs in place: one per source, in scan order,
/// drawn in the band's own colours. Done wears a check, the running one a spinner (a still
/// glyph under Reduce Motion), and the ones still waiting a dashed outline.
struct UpdateBandPhaseChips: View {
    let steps: [ScanPhaseStrip.Step]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(steps, id: \.phase) { step in
                chip(step)
            }
        }
        .accessibilityHidden(true)
    }

    private func chip(_ step: ScanPhaseStrip.Step) -> some View {
        HStack(spacing: 3) {
            glyph(step.state)
            Text(step.title)
        }
        .font(.wega(.caption2, weight: step.state == .running ? .semibold : .regular, monospaced: true))
        .foregroundStyle(step.state == .pending ? Color.wegaBandSecondaryText : Color.wegaBandText)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background { chipBackground(step.state) }
    }

    @ViewBuilder
    private func glyph(_ state: ScanPhaseStrip.StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
        case .running:
            if reduceMotion {
                Image(systemName: "ellipsis")
            } else {
                ProgressView().controlSize(.mini)
            }
        case .stopped:
            Image(systemName: "pause.fill")
        case .pending:
            Image(systemName: "circle.dotted")
        }
    }

    @ViewBuilder
    private func chipBackground(_ state: ScanPhaseStrip.StepState) -> some View {
        switch state {
        case .pending:
            Capsule().strokeBorder(Color.wegaBandSecondaryText.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        case .running:
            Capsule().fill(Color.wegaBandAccentText.opacity(0.2))
        case .done, .stopped:
            Capsule().fill(Color.wegaBandText.opacity(0.08))
        }
    }
}

/// UXP-13 — the round element while a scan runs: how many of the four sources have answered,
/// at exactly the button's diameter so nothing beside it moves when a scan starts or ends. The
/// narrow band has no room for Wega's head, so she sniffs inside the ring instead of the count.
struct UpdateBandScanRing: View {
    let completed: Int
    let total: Int
    let diameter: CGFloat
    let showsWega: Bool

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
            if showsWega {
                WegaHead(pose: .sniff, size: diameter * 0.62)
                    .sniffing(true)
                    .accessibilityHidden(true)
            } else {
                Text(verbatim: "\(completed)/\(total)")
                    .font(.wega(.title2, weight: .semibold, monospaced: true))
                    .foregroundStyle(Color.wegaBandText)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Postęp skanowania"))
        .accessibilityValue(UpdateBandScanPresentation.sourcesValue(completed: completed, total: total))
    }
}

extension View {
    /// Wega's sniffing head-bob while a scan runs — the same bob `WigglyWega` gives the first
    /// scan's scene. It goes through `ContinuousMotion`, so with Reduce Motion she holds still.
    func sniffing(_ active: Bool) -> some View {
        modifier(SniffingMotion(active: active))
    }
}

private struct SniffingMotion: ViewModifier {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bob = false

    func body(content: Content) -> some View {
        let moving = active && !reduceMotion
        content
            .rotationEffect(.degrees(moving ? (bob ? 2.4 : -2.4) : 0), anchor: .bottom)
            .offset(y: moving ? (bob ? -1 : 1) : 0)
            .onAppear { restart() }
            .onChange(of: active) { _, _ in restart() }
            .onChange(of: reduceMotion) { _, _ in restart() }
    }

    private func restart() {
        guard active, !reduceMotion else {
            bob = false
            return
        }
        let motion = ContinuousMotion.forever(.easeInOut(duration: 0.22), autoreverses: true, reduceMotion: reduceMotion)
        withAnimation(motion) { bob = true }
    }
}
