import SwiftUI
import MacUpdaterCore

/// Shows when the disabled list unlocks and dims it without blurring the rows. During
/// scanning a honey line also sweeps down the visible list.
///
/// Nothing blurs: in 0.8.0 the system's frosted glass over the rows blurred them into an empty
/// column, and a scan in place looked like a blank, frozen list.
struct ScanListVeil: View {
    enum Mode {
        case scanning, updating

        var message: String {
            switch self {
            case .scanning: return tr("Lista odblokuje się po skanie")
            case .updating: return tr("Lista odblokuje się po aktualizacji")
            }
        }
    }

    var mode: Mode = .scanning

    /// How much of the window's background lies over the rows: enough to read as locked, little
    /// enough that every row stays legible.
    static let scrimOpacity: Double = 0.5
    static let beamHeight: CGFloat = 28
    /// One sweep of the visible list, whatever its height.
    static let sweepPeriod: TimeInterval = 2.4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Reduce Transparency removes the scrim. The label still says the list is locked.
    static func scrim(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 0 : scrimOpacity
    }

    static func drawsBeam(reduceMotion: Bool) -> Bool {
        ContinuousMotion.loopsIdleAnimations(reduceMotion: reduceMotion)
    }

    /// The line's top edge at `time` over a list `height` tall: from just above the list to its
    /// bottom edge, linearly, once every `sweepPeriod`.
    static func beamTop(at time: TimeInterval, height: CGFloat) -> CGFloat {
        let phase = time.truncatingRemainder(dividingBy: sweepPeriod)
        let progress = CGFloat((phase < 0 ? phase + sweepPeriod : phase) / sweepPeriod)
        return -beamHeight + progress * (height + beamHeight)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(Self.scrim(reduceTransparency: reduceTransparency))
                .accessibilityHidden(true)
            if mode == .scanning && Self.drawsBeam(reduceMotion: reduceMotion) {
                GeometryReader { proxy in
                    TimelineView(.animation) { context in
                        beam.offset(y: Self.beamTop(at: context.date.timeIntervalSinceReferenceDate, height: proxy.size.height))
                    }
                }
                .accessibilityHidden(true)
            }
            label
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private var beam: some View {
        LinearGradient(
            stops: [
                .init(color: Color.wegaHoney.opacity(0), location: 0),
                .init(color: Color.wegaHoney.opacity(0.28), location: 0.5),
                .init(color: Color.wegaHoney.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: Self.beamHeight)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// On a solid band-coloured capsule, so Reduce Transparency changes nothing for it.
    private var label: some View {
        Label(mode.message, systemImage: "lock.fill")
            .font(.wega(.callout, weight: .semibold))
            .foregroundStyle(Color.wegaBandText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.wegaBandMid))
            .overlay(Capsule().strokeBorder(Color.wegaBandBorder, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mode.message)
    }
}
