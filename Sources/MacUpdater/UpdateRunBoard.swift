import Foundation
import SwiftUI
import MacUpdaterCore

/// C2 stage 3 — where one planned row, or one batch, has got to in the running update.
///
/// None of these says "updated" (REL-02): an install the tool reported is still waiting on
/// the canary and the rescan, and `installedChecking` says exactly that.
enum UpdateRunRowStatus: Equatable, Sendable {
    case waiting, installing, installedChecking, failed, notStarted

    /// Waiting after a stop request reads as `notStarted`.
    func title(isStopping: Bool) -> String {
        switch self {
        case .waiting:           return isStopping ? tr("nie zacznę") : tr("czeka")
        case .installing:        return tr("instaluję…")
        case .installedChecking: return tr("zainstalowano, sprawdzam")
        case .failed:            return tr("nie udało się")
        case .notStarted:        return tr("nie zacznę")
        }
    }

    /// A lane says „w toku” while installing; otherwise `title(isStopping:)`.
    func laneTitle(isStopping: Bool) -> String {
        self == .installing ? tr("w toku") : title(isStopping: isStopping)
    }
}

/// The two batches that answer for all their rows at once — one `brew upgrade` for every
/// formula, one `mas upgrade` for every App Store app — so their status belongs on a group
/// header rather than on any single row.
enum UpdateRunLane: Hashable, Sendable, CaseIterable {
    case formulae, appStore

    var title: String {
        switch self {
        case .formulae: return tr("Narzędzia Homebrew")
        case .appStore: return tr("Mac App Store")
        }
    }

    var kind: OutdatedItem.Kind {
        switch self {
        case .formulae: return .formula
        case .appStore: return .appStore
        }
    }

    /// Whether the lane asks the stop switch before it starts. The App Store batch does; the
    /// formula batch starts with the run and has no gate of its own, so a stop request never
    /// makes it read „nie zacznę”.
    var stopsBeforeStarting: Bool {
        switch self {
        case .formulae: return false
        case .appStore: return true
        }
    }
}

extension CaskValidationVerdict {
    /// Whether a cask the tool reported installed still leaves the run without a new version
    /// that passed its check: restored to the previous one, failed and not restorable, or
    /// never replaced on disk. Its row then reads `failed` rather than `installedChecking`.
    var failsTheRunRow: Bool {
        switch self {
        case .rolledBack, .publisherChangedAndRolledBack, .rollbackFailed, .notUpgraded:
            return true
        case .healthy, .publisherChanged, .replacedByAppUpdater:
            return false
        }
    }
}

/// C2 stage 3 — the store's record of a running update: when it started, which rows it is
/// about, and where each per-row lane and each batch has got to. `.idle` between runs.
///
/// Counts stay in `upgradeProgress` and the stop request in `updateInterruption`; the board
/// holds only what neither of them knows.
struct UpdateRunBoard: Equatable, Sendable {
    var startedAt: Date? = nil
    var planned: Set<String> = []
    /// Only `.cask` and `.npm` keys: the two sources whose lanes answer per row.
    var rows: [String: UpdateRunRowStatus] = [:]
    var lanes: [UpdateRunLane: UpdateRunRowStatus] = [:]

    static let idle = UpdateRunBoard()
}

/// What the update list reads off the board: a status per row, which rows step back, and
/// what a group header says for the batches it covers.
struct UpdateRunListState: Equatable {
    let board: UpdateRunBoard
    let isStopping: Bool

    /// `nil` for a formula or an App Store row: their batch speaks on the group header.
    func rowStatus(for item: OutdatedItem) -> UpdateRunRowStatus? {
        switch item.kind {
        case .cask, .npm:         return board.rows[item.key]
        case .formula, .appStore: return nil
        }
    }

    /// A row this run is not about. Nothing steps back before the run has opened its board.
    func isDimmed(_ key: String) -> Bool {
        board.startedAt != nil && !board.planned.contains(key)
    }

    /// The batches on the board whose rows a header with `kinds` groups, in
    /// `UpdateRunLane.allCases` order; `nil` when it groups none of them.
    func laneNote(for kinds: Set<OutdatedItem.Kind>) -> String? {
        let notes = UpdateRunLane.allCases.compactMap { lane -> String? in
            guard kinds.contains(lane.kind), let status = board.lanes[lane] else { return nil }
            return "\(lane.title): \(status.laneTitle(isStopping: isStopping && lane.stopsBeforeStarting))"
        }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }
}

private struct UpdateRunListKey: EnvironmentKey {
    static let defaultValue: UpdateRunListState? = nil
}

extension EnvironmentValues {
    /// C2 §4.6 — what the update list says about the running update; `nil` outside a run.
    var updateRun: UpdateRunListState? {
        get { self[UpdateRunListKey.self] }
        set { self[UpdateRunListKey.self] = newValue }
    }
}
