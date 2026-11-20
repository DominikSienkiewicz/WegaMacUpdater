import MacUpdaterCore
import SwiftUI

/// What a queue circle shows: not queued yet, queued, a group or list that is only partly
/// queued, or the hand-off mark of a row that is updated outside the app.
enum QueueCircleState: Equatable {
    case notQueued, queued, partial, handoff

    /// Maps a select-all state onto the circle that shows it.
    init(_ selection: SelectAllState) {
        switch selection {
        case .none: self = .notQueued
        case .all: self = .queued
        case .partial: self = .partial
        }
    }

    /// The SF Symbol drawn inside the circle; every state has its own, so the state never
    /// depends on colour alone.
    var symbolName: String {
        switch self {
        case .notQueued: return "plus"
        case .queued: return "checkmark"
        case .partial: return "minus"
        case .handoff: return "arrow.up.right"
        }
    }
}

/// The C2 queue circle: honey with an ink outline and ledge once queued, a dashed outline
/// before. It only draws, at exactly `WegaLayout.queueCircleSize` square.
struct QueueCircle: View {
    let state: QueueCircleState

    private var isHoney: Bool { state == .queued || state == .partial }

    var body: some View {
        ZStack {
            Image(systemName: state.symbolName)
                .font(.wega(.callout, weight: .bold))
                .foregroundStyle(isHoney ? AnyShapeStyle(Color.wegaInk) : AnyShapeStyle(.secondary))
        }
        .frame(width: WegaLayout.queueCircleSize, height: WegaLayout.queueCircleSize)
        .background { fillAndLedge }
        .overlay { outline }
    }

    @ViewBuilder private var fillAndLedge: some View {
        if isHoney {
            Circle()
                .fill(Color.wegaActionLedge)
                .offset(y: WegaLayout.queueCircleLedge)
            Circle().fill(Color.wegaHoneyFill)
        }
    }

    @ViewBuilder private var outline: some View {
        switch state {
        case .queued, .partial:
            Circle().strokeBorder(Color.wegaActionOutline, lineWidth: WegaLayout.queueCircleOutline)
        case .notQueued:
            Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        case .handoff:
            Circle().strokeBorder(.secondary, lineWidth: 1.5)
        }
    }
}

/// A `QueueCircle` that shows a keyboard focus ring while its control has focus. The ring
/// is an overlay, so focus never changes the layout size.
struct QueueCircleControlLabel: View {
    let state: QueueCircleState
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        QueueCircle(state: state)
            .overlay {
                if isFocused {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                }
            }
    }
}

/// The checkbox style of the per-row queue circle: Wega's drawing, macOS's semantics.
/// Like `WegaCheckboxToggleStyle` it owns the accessibility traits and value, so the
/// control still reads as a checkbox. The label is not drawn: call sites pass `EmptyView()`
/// and name the control with `.accessibilityLabel`.
struct WegaQueueToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            QueueCircleControlLabel(state: configuration.isOn ? .queued : .notQueued)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : .isToggle)
        .accessibilityValue(selectionAccessibilityValue(configuration.isOn))
    }
}

/// The mark on a row whose update happens outside the app. It is not a control: hidden from
/// accessibility and not focusable, so the row's own action stays the only thing to operate.
struct QueueHandoffMark: View {
    var body: some View {
        QueueCircle(state: .handoff)
            .accessibilityHidden(true)
    }
}
