import Foundation
import MacUpdaterCore

/// C2 stage 4 — what the band says once a run has been checked: the run's status and time
/// range, how many planned items were updated, Wega's line, and one count per result that
/// happened. It keeps the report and words it when read, so a language switch re-words it.
///
/// Counts use "Etykieta: N", so no plural forms are needed; only non-zero ones are shown.
struct UpdateBandSummaryPresentation: Equatable {
    let report: UpdateRunReport
    /// Wega's line from the run's report („Gotowe!…”, „Część pakietów…”, „Przerwałam…”).
    let wegaLine: String
    /// `false` when a source of the check did not answer; the headline then says so.
    let scanComplete: Bool
    /// The current list's updates finished with the developer — not part of the run.
    let handOffCount: Int
    /// The earliest expiry of this run's undos, for the "Zaktualizowano" line.
    let undoExpiry: Date?

    /// "Aktualizacja niekompletna · 08:14–08:19".
    var eyebrow: String {
        let start = report.startedAt.formatted(date: .omitted, time: .shortened)
        let end = report.finishedAt.formatted(date: .omitted, time: .shortened)
        return "\(report.statusTitle) · \(start)–\(end)"
    }

    /// The eyebrow without its time range, for a column too narrow for both.
    var shortEyebrow: String { report.statusTitle }

    /// "Zaktualizowano 4 z 5", with " · skan niepełny" right after it when the check was
    /// incomplete, before anything truncation could cut.
    var headline: String {
        scanComplete ? ringValue : ringValue + " · " + tr("skan niepełny")
    }

    var line: String { wegaLine }

    /// One line per non-zero count, in the result order; the updated line names its backup.
    var countLines: [String] {
        counts.map { count in
            guard count.isUpdated, let undoExpiry else { return count.text }
            return count.text + " · " + trf("kopia do %@", Self.backupDate(undoExpiry))
        }
    }

    /// Day and month only: a backup lasts a week (`UpdateOperationStore.retentionInterval`), and
    /// with the year „Zaktualizowano: 12 · kopia do 14 lut 2027” needs 199 pt of the regular
    /// column's 190 pt.
    static func backupDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The compact band's row: every non-zero count but "Zaktualizowano", which the headline
    /// already says. Empty when only updates happened.
    var compactCounts: String {
        counts.filter { !$0.isUpdated }.map(\.text).joined(separator: " · ")
    }

    /// Every non-zero count, for the tooltip and VoiceOver.
    var allCounts: String {
        counts.map(\.text).joined(separator: " · ")
    }

    var updated: Int { report.updatedCount }

    var planned: Int { report.plannedCount }

    /// What VoiceOver hears for the result ring, and the headline without its note.
    var ringValue: String { trf("Zaktualizowano %@ z %@", "\(updated)", "\(planned)") }

    /// One labelled count; `isUpdated` marks the one the headline already says.
    private struct Count {
        let text: String
        let value: Int
        var isUpdated = false
    }

    private var counts: [Count] {
        let updated = report.count(.updated)
        let failed = report.count(.failed)
        let rolledBack = report.count(.rolledBack)
        let notConfirmed = report.count(.notConfirmed)
        let notStarted = report.count(.notStarted)
        let all = [
            Count(text: trf("Zaktualizowano: %@", "\(updated)"), value: updated, isUpdated: true),
            Count(text: trf("Nie udało się: %@", "\(failed)"), value: failed),
            Count(text: trf("Cofnięto: %@", "\(rolledBack)"), value: rolledBack),
            Count(text: trf("Bez potwierdzenia: %@", "\(notConfirmed)"), value: notConfirmed),
            Count(text: trf("Nie zaczęłam: %@", "\(notStarted)"), value: notStarted),
            Count(text: trf("U producenta: %@", "\(handOffCount)"), value: handOffCount),
        ]
        return all.filter { $0.value > 0 }
    }

    /// The earliest expiry among this run's undos of the items it updated (`report.undo(for:in:)`).
    static func earliestUndoExpiry(of report: UpdateRunReport, in undoables: [UndoableUpdate]) -> Date? {
        report.entries
            .filter { $0.result == .updated }
            .compactMap { report.undo(for: $0, in: undoables)?.expiresAt }
            .min()
    }
}
