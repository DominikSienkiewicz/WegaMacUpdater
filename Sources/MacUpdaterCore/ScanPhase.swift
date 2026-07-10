import Foundation

/// The stages of an update scan, in the order it actually performs them (M2c).
///
/// The scan queries Homebrew, then the Mac App Store, then npm, then the manual checkers —
/// strictly one after another. That makes honest progress cheap to report, which matters
/// because the old "checking" screen animated five invented command bars on a timer while
/// the real work happened somewhere else, for however long it took.
public enum ScanPhase: CaseIterable, Equatable, Sendable {
    case brew
    case mas
    case npm
    case manual

    /// What the phase is doing, named after the command it runs.
    public var commandLabel: String {
        switch self {
        case .brew:   return "brew outdated"
        case .mas:    return "mas outdated"
        case .npm:    return "npm outdated -g"
        case .manual: return "sparkle · cask check"
        }
    }

    /// Progress *completed before* this phase starts. Reporting finished work rather than
    /// work-in-progress is why the last phase sits at 0.75 rather than 1.0: the bar reaches
    /// the end when the scan does, not when its final query begins.
    public var fractionCompleted: Double {
        guard let index = Self.allCases.firstIndex(of: self) else { return 0 }
        return Double(index) / Double(Self.allCases.count)
    }
}

/// Where a scan currently stands. `cancelled` keeps the phase it stopped at, so the UI can
/// say "stopped after mas" instead of silently snapping back to zero or to complete.
public enum ScanProgress: Equatable, Sendable {
    case running(ScanPhase)
    case finished
    case cancelled(at: ScanPhase)

    public var fractionCompleted: Double {
        switch self {
        case .running(let phase):     return phase.fractionCompleted
        case .finished:               return 1
        case .cancelled(let phase):   return phase.fractionCompleted
        }
    }

    /// Only a scan that is still going can be stopped.
    public var isCancellable: Bool {
        if case .running = self { return true }
        return false
    }
}
