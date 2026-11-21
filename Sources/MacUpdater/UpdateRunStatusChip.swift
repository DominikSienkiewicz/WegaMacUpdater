import SwiftUI
import MacUpdaterCore

/// C2 §4.6 — one row's place in the running update, in the version's column. Every state has a
/// word as well as a glyph, and none says "updated" (REL-02).
struct UpdateRunStatusChip: View {
    let status: UpdateRunRowStatus
    let isStopping: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            glyph
            Text(status.title(isStopping: isStopping))
        }
        .font(.wega(.caption))
        .foregroundStyle(tint)
        .lineLimit(1)
    }

    @ViewBuilder
    private var glyph: some View {
        switch status {
        case .installing:
            if reduceMotion {
                Image(systemName: "ellipsis")
            } else {
                ProgressView().controlSize(.mini)
            }
        case .waiting:
            Image(systemName: isStopping ? "forward.end" : "clock")
        case .installedChecking:
            Image(systemName: "hourglass")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
        case .notStarted:
            Image(systemName: "forward.end")
        }
    }

    private var tint: Color {
        switch status {
        case .installing: return Color.wegaHoney
        case .failed:     return Color.wegaDanger
        default:          return .secondary
        }
    }
}
