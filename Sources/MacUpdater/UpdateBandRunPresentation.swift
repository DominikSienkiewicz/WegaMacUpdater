import Foundation
import MacUpdaterCore

/// C2 stage 3 — what the band says while an update runs, decided away from the views: since
/// when, the stage the run is on, how many packages are done and how to stop it. Like the scan
/// state, it counts what has happened and never estimates what is left.
struct UpdateBandRunPresentation: Equatable {
    /// The store's progress; `nil` for the moment before the run counts its batch.
    let progress: UpgradeProgress?
    /// When the run started, from the run board.
    let startedAt: Date?
    /// Whether a stop was requested; the stop then says it is finishing what has started.
    let isStopping: Bool
    /// Whether the run's log is open under the list; the band offers „Pokaż log” only when not.
    let logShown: Bool

    /// "Trwa aktualizacja · od 08:14" — when the run started, not how long it may take.
    var eyebrow: String {
        guard let startedAt else { return tr("Trwa aktualizacja") }
        return trf("Trwa aktualizacja · od %@", startedAt.formatted(date: .omitted, time: .shortened))
    }

    var headline: String { tr("Aktualizuję wybrane pakiety") }

    /// The stage. Before the run has counted its batch it is still taking backups.
    var line: String {
        UpgradeProgressCopy.label(for: progress ?? UpgradeProgress(completedUnits: 0, totalUnits: 0, stage: .preparing))
    }

    /// "1 z 5"; `nil` before the run has counted its batch.
    var counter: String? { progress.map(UpgradeProgressCopy.counter(for:)) }

    var completed: Int { progress?.completedUnits ?? 0 }

    var total: Int { progress?.totalUnits ?? 0 }

    var stopLabel: String { UpdateRunCopy.stopLabel(isStopping: isStopping) }
}

/// The upgrade's progress in words, in whole packages finished out of the batch the run planned.
///
/// There is no percentage to show: piped brew runs curl with `--silent`, so the bytes are
/// invisible from here (see `INSTALL_PROGRESS_DESIGN.md`). What the run reports is finished
/// work — the rule the scan already follows — and the label names the phase, plus the package
/// whenever the run can honestly name one: brew announces its own, npm's loop already knows
/// it, and the App Store's one opaque call names nothing.
enum UpgradeProgressCopy {
    /// "1 z 5": the packages finished out of the batch.
    static func counter(for progress: UpgradeProgress) -> String {
        trf("%@ z %@", "\(progress.completedUnits)", "\(progress.totalUnits)")
    }

    /// The phase, then the package when it can be named, then the counter.
    static func label(for progress: UpgradeProgress) -> String {
        let counter = counter(for: progress)
        switch progress.stage {
        case .preparing:
            return tr("Przygotowuję kopie zapasowe…")
        case .downloading(let token?):
            return trf("Pobieram %@ — %@", "\(token)", "\(counter)")
        case .downloading:
            return trf("Pobieram pakiety — %@", "\(counter)")
        case .installing(let token?):
            return trf("Instaluję %@ — %@", "\(token)", "\(counter)")
        case .installing:
            return trf("Instaluję pakiety — %@", "\(counter)")
        }
    }
}

/// UX-20 — what the run says about stopping, before and after the stop is requested.
///
/// Stopping keeps REL-12's contract: the package being installed finishes, and nothing queued
/// after it starts. The stop says so rather than promising an instant stop.
enum UpdateRunCopy {
    static func stopLabel(isStopping: Bool) -> String {
        isStopping
            ? tr("Kończę rozpoczęte instalacje, nowych nie zaczynam")
            : tr("Zatrzymaj po rozpoczętych instalacjach")
    }

    static func note(isStopping: Bool) -> String {
        isStopping
            ? tr("Przerywam po bieżącym pakiecie — kolejne nie wystartują.")
            : tr("Do końca aktualizacji lista jest zablokowana. Możesz ją przerwać — bieżący pakiet dokończę, kolejnych nie zacznę.")
    }

    /// The list header's note while a run holds the list; `note(isStopping: false)` is its tooltip.
    static var lockNote: String { tr("Do końca aktualizacji lista jest zablokowana.") }

    /// The stop's tooltip: it never cuts an install in half.
    static var stopHelp: String { tr("Zatrzymam po bieżącym pakiecie — trwającej instalacji nie przerywam w połowie.") }
}
