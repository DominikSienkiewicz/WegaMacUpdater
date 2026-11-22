import SwiftUI
import MacUpdaterCore

/// What stands where the update button would when nothing needs updating (owner, 2026-11-22): a
/// full ring with a check after a complete scan, a bare ring with a question mark after an
/// incomplete one. It is the button's size, so the ↻ beside it keeps its place when a scan ends.
/// The headline says the same in words, so VoiceOver skips the mark.
struct UpdateBandUpToDateMark: View {
    let complete: Bool
    let diameter: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    private var lineWidth: CGFloat { max(4, diameter * 0.07) }

    /// The palette's dark success value, like the result ring's: the band is always dark.
    private var tint: Color {
        complete
            ? Color(nsColor: WegaPalette.success.components(isDark: true, increasedContrast: contrast == .increased).nsColor)
            : Color.wegaBandSecondaryText
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(complete ? tint : Color.wegaBandText.opacity(0.16), lineWidth: lineWidth)
            Image(systemName: complete ? "checkmark" : "questionmark")
                .font(.wega(.title, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}
