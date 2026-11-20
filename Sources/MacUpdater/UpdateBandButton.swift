import SwiftUI

/// The band's round update button: a honey disc with an ink ledge while it can run, a dashed
/// empty ring while it cannot. The caller owns the gate; this view only draws `isEnabled`.
struct UpdateBandButton: View {
    let title: String
    let count: Int?
    let accessibilityLabel: String
    let diameter: CGFloat
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label
                .frame(width: diameter, height: diameter)
                .background { disc }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.wega(.callout, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(.wega(.title, weight: .bold, monospaced: true))
                    .minimumScaleFactor(0.6)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 10)
        .foregroundStyle(isEnabled ? Color.wegaInk : Color.wegaBandSecondaryText)
    }

    @ViewBuilder
    private var disc: some View {
        if isEnabled {
            Circle()
                .fill(Color.wegaBandButtonLedge)
                .offset(y: WegaLayout.bandButtonLedge)
                .overlay {
                    Circle()
                        .fill(RadialGradient(
                            colors: [.wegaBandButtonHighlight, .wegaBandButtonCore, .wegaBandButtonRim],
                            center: UnitPoint(x: 0.35, y: 0.28),
                            startRadius: 0,
                            endRadius: diameter * 0.85
                        ))
                        .overlay { Circle().strokeBorder(Color.wegaBandButtonOutline, lineWidth: 2) }
                }
        } else {
            Circle()
                .strokeBorder(Color.wegaBandSecondaryText, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        }
    }
}
