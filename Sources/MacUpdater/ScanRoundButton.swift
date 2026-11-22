import SwiftUI
import MacUpdaterCore

/// What the round scan button offers right now. The stop follows what `cancelScan()` can stop. A
/// check after a run or an undo cannot be cancelled, so it shows a greyed-out start, never a stop
/// that does nothing.
enum ScanRoundButtonState: Equatable {
    case start(enabled: Bool)
    case cancel

    static func resolve(canStartCheck: Bool, canCancelScan: Bool) -> Self {
        canCancelScan ? .cancel : .start(enabled: canStartCheck)
    }
}

/// The scan action, where the scan is reported (owner, 2026-11-22, option B): beside the band's
/// big circle, „Wszystko aktualne” included, and in the first scan's scene. It replaced
/// the toolbar's „Sprawdź teraz”/„Anuluj”, which was hard to find. ⌘R and ⌘. still work from every
/// screen. One size in every state, so nothing beside it moves when a scan starts or ends.
struct ScanRoundButton: View {
    /// `.band` draws in the band's fixed colours, which stay readable on its always-dark ground;
    /// `.window` follows the window's appearance.
    enum Style { case band, window }

    let state: ScanRoundButtonState
    var style: Style = .window
    let onStart: () -> Void
    let onCancel: () -> Void

    static let diameter: CGFloat = 40

    private var label: String {
        state == .cancel ? tr("Anuluj skan") : tr("Sprawdź teraz")
    }

    private var symbol: String {
        state == .cancel ? "stop.fill" : "arrow.clockwise"
    }

    private var isEnabled: Bool {
        if case .start(let enabled) = state { return enabled }
        return true
    }

    var body: some View {
        Button(action: state == .cancel ? onCancel : onStart) {
            Image(systemName: symbol)
                .font(.wega(.body, weight: .semibold))
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background { Circle().strokeBorder(stroke, lineWidth: 1.5) }
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .frame(width: Self.diameter, height: Self.diameter)
        .help(label)
        .accessibilityLabel(label)
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .band:   AnyShapeStyle(Color.wegaBandText)
        case .window: AnyShapeStyle(.primary)
        }
    }

    private var stroke: AnyShapeStyle {
        switch style {
        case .band:   AnyShapeStyle(Color.wegaBandText.opacity(0.6))
        case .window: AnyShapeStyle(.secondary)
        }
    }
}
