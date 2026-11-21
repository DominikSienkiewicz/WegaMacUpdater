import SwiftUI
import MacUpdaterCore

/// UX-19 — where an in-place scan is, one chip per source, in the order the scan queries them.
///
/// It replaces the one-line "odświeżam… brew outdated" stamp in the Updates header. The scan
/// is strictly sequential (`ScanPhase`), so every phase before the current one is done and
/// every phase after it has not started — nothing here is estimated. Before the first phase
/// is reported, nothing is claimed.
struct ScanPhaseStrip: View {
    let progress: ScanProgress?

    enum StepState: Equatable { case done, running, stopped, pending }

    struct Step: Equatable {
        let phase: ScanPhase
        let state: StepState
        let title: String
    }

    static func steps(for progress: ScanProgress?) -> [Step] {
        let phases = ScanPhase.allCases
        return phases.enumerated().map { index, phase in
            Step(phase: phase, state: state(of: index, in: progress), title: title(of: phase))
        }
    }

    private static func state(of index: Int, in progress: ScanProgress?) -> StepState {
        let phases = ScanPhase.allCases
        switch progress {
        case .none:
            return .pending
        case .finished:
            return .done
        case .running(let current):
            let currentIndex = phases.firstIndex(of: current) ?? 0
            return index < currentIndex ? .done : (index == currentIndex ? .running : .pending)
        case .cancelled(let current):
            let currentIndex = phases.firstIndex(of: current) ?? 0
            return index < currentIndex ? .done : (index == currentIndex ? .stopped : .pending)
        }
    }

    private static func title(of phase: ScanPhase) -> String {
        switch phase {
        case .brew:   return "Homebrew"
        case .mas:    return "App Store"
        case .npm:    return "npm"
        case .manual: return tr("Producenci")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.steps(for: progress), id: \.phase) { step in
                chip(step)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Trwa skanowanie"))
        .accessibilityValue(ScanBusyPresentation(progress: progress).accessibilityValue)
    }

    private func chip(_ step: Step) -> some View {
        HStack(spacing: 4) {
            switch step.state {
            case .done:
                Image(systemName: "checkmark").foregroundStyle(Color.wegaSuccess)
            case .running:
                ProgressView().controlSize(.mini)
            case .stopped:
                Image(systemName: "pause.fill").foregroundStyle(.secondary)
            case .pending:
                Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
            }
            Text(step.title)
                .foregroundStyle(step.state == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .font(.wega(.footnote, weight: step.state == .running ? .semibold : .regular))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(chipBackground(step.state), in: Capsule())
    }

    private func chipBackground(_ state: StepState) -> Color {
        switch state {
        case .done:    return Color.wegaSuccess.opacity(0.12)
        case .running: return Color.wegaHoney.opacity(0.16)
        case .stopped, .pending: return Color.primary.opacity(0.05)
        }
    }
}
