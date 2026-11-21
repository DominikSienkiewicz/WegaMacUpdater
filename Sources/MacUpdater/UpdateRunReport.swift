import Foundation
import MacUpdaterCore

/// C2 stage 4 — how one planned item ended the run, after every phase it had to clear.
enum UpdateRunResult: Equatable, Sendable, CaseIterable {
    case updated, failed, rolledBack, notConfirmed, notStarted
}

/// What the check after the run said about an item it had to confirm.
enum UpdateRunCheckAnswer: Equatable, Sendable {
    case confirmed, stillListed, unanswered
}

/// One planned row of a finished run, as the after-update summary shows it.
///
/// It keeps the verdict, never a sentence: `tr()` is not reactive, so a row worded when the
/// run ended would stay in that language after a switch. `note(undo:)` words it when read.
struct UpdateRunReportEntry: Equatable, Sendable, Identifiable {
    let key: String
    let name: String
    let kind: OutdatedItem.Kind
    let from: String?
    let to: String?
    /// `nil` when nothing was attempted for the item.
    let verdict: ItemUpdateVerdict?
    /// The stop switch skipped it (`UpdateInterruption.skippedKeys`).
    let wasSkipped: Bool
    /// `.publisherChanged` only: what the check after the run said about it. `.confirmed` for
    /// every other verdict (Core's `applyRescan` already folded the check into those).
    let checkAnswer: UpdateRunCheckAnswer
    /// The bundle the run prepared for this cask (`caskPreparation.appPaths`); `nil` otherwise.
    let appPath: URL?
    /// Set by `ScanStore` after an undo from the summary restored it.
    var undoneTo: String?
    /// Set by `ScanStore` after "Zaufaj nowemu podpisowi" was accepted or found already trusted.
    var publisherSettled: Bool
    var id: String { key }

    var result: UpdateRunResult {
        guard let verdict else { return .notStarted }
        switch verdict {
        case .succeeded:
            return .updated
        case .publisherChanged:
            switch checkAnswer {
            case .confirmed:   return .updated
            case .stillListed: return .failed
            case .unanswered:  return .notConfirmed
            }
        case .rolledBack, .publisherChangedAndRolledBack:
            return .rolledBack
        case .notVerified:
            return .notConfirmed
        case .publisherMismatchBeforeUpgrade:
            return .notStarted
        case .stillOutdated, .executionFailed, .executionFailedAfterRollback, .executionFailedAfterPublisherRollback,
             .executionFailedWithPublisherChange, .rollbackFailed:
            return .failed
        }
    }

    /// A changed publisher needs attention even when the check confirmed the new version.
    var group: UpdateRunReport.Group {
        switch result {
        case .notStarted:                        return .notStarted
        case .updated:                           return verdict == .succeeded ? .updated : .needsAttention
        case .failed, .rolledBack, .notConfirmed: return .needsAttention
        }
    }

    /// Whether the row offers "Zaufaj nowemu podpisowi" (a cask whose new or current publisher
    /// differs, not settled, not rolled back) — today's `trustPublisherAction` rule.
    var offersPublisherTrust: Bool {
        guard kind == .cask, !publisherSettled else { return false }
        switch verdict {
        case .publisherChanged?, .executionFailedWithPublisherChange?, .publisherMismatchBeforeUpgrade?: return true
        default: return false
        }
    }

    /// The Team ID that action passes to `trustNewPublisher(token:reportedTeamID:)`.
    var reportedTeamID: String? {
        switch verdict {
        case .publisherChanged(_, let new)?, .executionFailedWithPublisherChange(_, let new)?: return new
        case .publisherMismatchBeforeUpgrade(_, let current)?:                                 return current
        default:                                                                               return nil
        }
    }

    /// Every verdict that raises "Zmienił się podpis producenta", rolled back or not.
    var hasPublisherChange: Bool { publisherSentence != nil }

    /// The words today's "Zmienił się podpis producenta" banner uses for this verdict, worded
    /// now: the row's note and the sticky banner raised when the summary closes.
    var publisherSentence: String? {
        switch verdict {
        case .publisherChanged(let old, let new)?, .executionFailedWithPublisherChange(let old, let new)?:
            return trf("%@: zmienił się podpis producenta (%@ → %@). Zaufaj nowemu podpisowi tylko wtedy, gdy producent zmienił konto.",
                       "\(name)", "\(old)", "\(new ?? "—")")
        case .publisherChangedAndRolledBack(let old, let new)?, .executionFailedAfterPublisherRollback(let old, let new)?:
            return trf("%@: zmienił się podpis producenta (%@ → %@). Przywróciłam poprzednią zaufaną wersję.",
                       "\(name)", "\(old)", "\(new ?? "—")")
        case .publisherMismatchBeforeUpgrade(let old, let current)?:
            return trf("%@: podpis producenta już przed aktualizacją różnił się od zaufanego (%@ → %@). Aktualizację zablokowałam. Zaufaj nowemu podpisowi tylko wtedy, gdy producent zmienił konto.",
                       "\(name)", "\(old)", "\(current ?? "—")")
        default:
            return nil
        }
    }

    /// The row's sentence, worded now (re-read after a language switch). `undo` is this run's
    /// undo for the item, when one exists.
    func note(undo: UndoableUpdate?) -> String {
        guard let verdict else {
            return wasSkipped ? tr("zatrzymano przed startem") : tr("nie uruchomiłam — szczegóły w logu")
        }
        switch verdict {
        case .succeeded:
            return updatedNote(undo: undo)
        case .publisherChanged, .executionFailedWithPublisherChange, .publisherMismatchBeforeUpgrade:
            return publisherSettled ? tr("Zaufano nowemu podpisowi") : publisherSentence ?? ""
        case .publisherChangedAndRolledBack, .executionFailedAfterPublisherRollback:
            return publisherSentence ?? ""
        case .executionFailed, .executionFailedAfterRollback:
            return tr("nie udało się — szczegóły w logu")
        case .stillOutdated:
            return tr("nadal nieaktualna po sprawdzeniu")
        case .rolledBack:
            return tr("nowa wersja nie przeszła kontroli — przywróciłam poprzednią")
        case .rollbackFailed:
            return trf("%@: nowa wersja nie przeszła kontroli, a przywrócenie poprzedniej nie powiodło się. Sprawdź aplikację przed użyciem.", "\(name)")
        case .notVerified:
            return tr("zainstalowano, ale sprawdzenie nie potwierdziło wyniku")
        }
    }

    private func updatedNote(undo: UndoableUpdate?) -> String {
        if let undoneTo { return trf("cofnięto do %@", undoneTo) }
        if let undo { return trf("kopia do %@", undo.expiresAt.formatted(date: .abbreviated, time: .omitted)) }
        if kind == .cask, DockerDesktopMutationGate.isDocker(token: name) {
            return tr("Pakiety zainstalowane. Gotowość silnika Docker nie była sprawdzana.")
        }
        return tr("bez cofnięcia")
    }
}

/// C2 stage 4 — what one window run did to every row it planned, for the after-update
/// summary. Built once by `make` when the run is reported; afterwards only `ScanStore` marks
/// an undo or a trusted publisher on it.
struct UpdateRunReport: Equatable, Sendable {
    enum Group: CaseIterable { case needsAttention, notStarted, updated }
    enum Status { case finished, incomplete, stopped }

    let startedAt: Date
    let finishedAt: Date
    let wasStopped: Bool
    /// The run's cask operation, which owns this run's undos; `nil` when no cask ran.
    let caskOperationID: UUID?
    private(set) var entries: [UpdateRunReportEntry]

    /// One entry per planned key, in plan order. The parameters with a default describe a run
    /// that stopped nothing, prepared no cask and kept its own start time. `confirmed` is the
    /// answer Core's `applyRescan` was given: the check heard from every source the plan touched.
    static func make(planned: [OutdatedItem], summary: UpdateRunSummary,
                     skippedKeys: Set<String> = [], wasStopped: Bool = false,
                     startedAt: Date? = nil, finishedAt: Date,
                     caskOperationID: UUID? = nil, caskAppPaths: [String: URL] = [:],
                     stillOutdatedKeys: Set<String>,
                     confirmed: Bool) -> UpdateRunReport {
        let verdicts = Dictionary(summary.items.map { ($0.key, $0.verdict) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let entries = planned.compactMap { item -> UpdateRunReportEntry? in
            guard seen.insert(item.key).inserted else { return nil }
            let verdict = verdicts[item.key]
            return UpdateRunReportEntry(
                key: item.key, name: item.name, kind: item.kind, from: item.from, to: item.to,
                verdict: verdict,
                wasSkipped: skippedKeys.contains(item.key),
                checkAnswer: checkAnswer(for: verdict, key: item.key,
                                         stillOutdatedKeys: stillOutdatedKeys, confirmed: confirmed),
                appPath: item.kind == .cask ? caskAppPaths[item.name] : nil,
                undoneTo: nil,
                publisherSettled: false
            )
        }
        return UpdateRunReport(startedAt: startedAt ?? finishedAt, finishedAt: finishedAt, wasStopped: wasStopped,
                               caskOperationID: caskOperationID, entries: entries)
    }

    /// Core's `applyRescan` downgrades only `.succeeded`, so a changed publisher the check
    /// still lists, or could not answer for, would otherwise count as updated. It is answered
    /// all or nothing, as Core answers the rest of the run: with any source unheard it is
    /// unconfirmed, the cask source's own answer notwithstanding.
    private static func checkAnswer(
        for verdict: ItemUpdateVerdict?, key: String,
        stillOutdatedKeys: Set<String>, confirmed: Bool
    ) -> UpdateRunCheckAnswer {
        guard case .publisherChanged? = verdict else { return .confirmed }
        if stillOutdatedKeys.contains(key) { return .stillListed }
        return confirmed ? .confirmed : .unanswered
    }

    var status: Status {
        if wasStopped { return .stopped }
        return entries.allSatisfy { $0.result == .updated } ? .finished : .incomplete
    }

    /// Whether the open summary holds Wega's ball: a run that did not finish, or one with a row
    /// in „Wymaga uwagi” — a confirmed changed publisher finishes the run, and its banner waits
    /// for the summary to close.
    var holdsAttention: Bool { status != .finished || !entries(in: .needsAttention).isEmpty }

    /// The failure log's headline: every row the summary shows as not updated, in plan order.
    /// Polish, like every `WegaLog` message.
    var failureLogHeadline: String {
        let names = namesNeedingAttention
        return names.isEmpty ? "Aktualizacja niekompletna" : "Aktualizacja niekompletna: \(names.joined(separator: ", "))"
    }

    /// One line for each such row Core's summary cannot name: a planned row nothing attempted,
    /// and a changed publisher the check did not confirm (Core counts it as upgraded). The rows
    /// in `summary.notUpgraded` keep `report(run:)`'s own per-outcome lines.
    var failureLogLinesBeyondTheSummary: [String] {
        entries.compactMap { entry in
            guard let verdict = entry.verdict else {
                let reason = entry.wasSkipped ? "zatrzymano przed startem" : "nie uruchomiono — żaden etap aktualizacji nie objął tej pozycji"
                return "\(entry.name): \(reason)"
            }
            guard case .publisherChanged = verdict, entry.result != .updated else { return nil }
            let check = entry.checkAnswer == .stillListed
                ? "nadal widnieje jako nieaktualne po skanie kontrolnym"
                : "skan po aktualizacji nie potwierdził wyniku"
            return "\(entry.name): \(verdict.logDescription) — \(check)"
        }
    }

    /// `.finished` → the success eyebrow "Zaktualizowano %@ pakietów"; `.incomplete` →
    /// "Aktualizacja niekompletna"; `.stopped` → "Aktualizacja przerwana".
    var statusTitle: String {
        switch status {
        case .finished:   return trp("Zaktualizowano %@ pakietów", updatedCount)
        case .incomplete: return tr("Aktualizacja niekompletna")
        case .stopped:    return tr("Aktualizacja przerwana")
        }
    }

    /// Wega's line for the run, worded from its status when read: the three lines `report(run:)`
    /// says when the run ends. The summary shows this one, not Wega's current line, which a
    /// sidebar click or the check after an undo replaces while the summary stays open.
    var wegaLine: String {
        switch status {
        case .finished:   return trp("Gotowe! %@ pakietów odświeżonych.", updatedCount)
        case .incomplete: return tr("Część pakietów się nie zaktualizowała.")
        case .stopped:    return tr("Przerwałam aktualizację.")
        }
    }

    var plannedCount: Int { entries.count }
    var updatedCount: Int { count(.updated) }

    /// Names of every entry whose result is not `.updated`, in plan order (the announcement).
    var namesNeedingAttention: [String] {
        entries.filter { $0.result != .updated }.map(\.name)
    }

    func count(_ result: UpdateRunResult) -> Int {
        entries.filter { $0.result == result }.count
    }

    func entries(in group: Group) -> [UpdateRunReportEntry] {
        entries.filter { $0.group == group }
    }

    /// This run's undo for `entry`: an undo with the entry's token and `caskOperationID`;
    /// `nil` without an operation, for a non-cask, or once `undoneTo` is set.
    func undo(for entry: UpdateRunReportEntry, in undoables: [UndoableUpdate]) -> UndoableUpdate? {
        guard let caskOperationID, entry.kind == .cask, entry.undoneTo == nil else { return nil }
        return undoables.first { $0.operationID == caskOperationID && $0.token == entry.name }
    }

    /// Entries with a publisher change (any verdict that raises "Zmienił się podpis
    /// producenta") that are not `publisherSettled`, in plan order.
    var unsettledPublisherChanges: [UpdateRunReportEntry] {
        entries.filter { $0.hasPublisherChange && !$0.publisherSettled }
    }

    mutating func markUndone(token: String, restoredVersion: String?) {
        for index in entries.indices where entries[index].kind == .cask && entries[index].name == token {
            entries[index].undoneTo = restoredVersion ?? "—"
        }
    }

    mutating func settlePublisher(token: String) {
        for index in entries.indices
        where entries[index].kind == .cask && entries[index].name == token && entries[index].hasPublisherChange {
            entries[index].publisherSettled = true
        }
    }
}
