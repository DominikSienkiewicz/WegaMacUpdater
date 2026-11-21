import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// C2 stage 4 — the run's report places every planned item in exactly one result, says a
/// partial run is not a finished one, and words its rows only when they are read.
@Suite("Update run report") @MainActor
struct UpdateRunReportTests {
    private static let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let changedSentence =
        "%@: zmienił się podpis producenta (%@ → %@). Zaufaj nowemu podpisowi tylko wtedy, gdy producent zmienił konto."

    private func item(_ name: String, _ kind: OutdatedItem.Kind) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: kind), name: name, from: "1", to: "2", kind: kind)
    }

    private func outcome(_ item: OutdatedItem, _ verdict: ItemUpdateVerdict) -> ItemUpdateOutcome {
        ItemUpdateOutcome(key: item.key, name: item.name, kind: item.kind, verdict: verdict)
    }

    private func report(
        _ planned: [OutdatedItem], _ outcomes: [ItemUpdateOutcome],
        skipped: Set<String> = [], wasStopped: Bool = false,
        operationID: UUID? = nil, appPaths: [String: URL] = [:],
        stillOutdated: Set<String> = [], confirmed: Bool = true
    ) -> UpdateRunReport {
        UpdateRunReport.make(
            planned: planned,
            summary: UpdateRunSummary(items: outcomes, diagnostics: [], needsSudoPassword: false),
            skippedKeys: skipped, wasStopped: wasStopped,
            startedAt: nil, finishedAt: Self.finishedAt,
            caskOperationID: operationID, caskAppPaths: appPaths,
            stillOutdatedKeys: stillOutdated, confirmed: confirmed
        )
    }

    private func entry(_ name: String, in report: UpdateRunReport) -> UpdateRunReportEntry? {
        report.entries.first { $0.name == name }
    }

    private func undoable(_ token: String, operationID: UUID) -> UndoableUpdate {
        UndoableUpdate(operationID: operationID, token: token, appPath: "/Applications/\(token).app",
                       restoredVersion: "1", updatedAt: Self.finishedAt,
                       expiresAt: Self.finishedAt.addingTimeInterval(7 * 86_400))
    }

    @Test func everyPlannedItemLandsInExactlyOneResult() {
        withLanguage(.pl) {
            let planned = [item("alpha", .cask), item("beta", .formula), item("gamma", .cask), item("delta", .npm),
                           item("epsilon", .cask), item("Zeta", .appStore), item("eta", .formula)]
            let built = report(planned, [
                outcome(planned[0], .succeeded),
                outcome(planned[1], .executionFailed),
                outcome(planned[2], .rolledBack),
                outcome(planned[3], .notVerified),
                outcome(planned[4], .publisherMismatchBeforeUpgrade(old: "AAA", current: "BBB")),
            ], skipped: [planned[5].key])

            #expect(built.entries.count == 7)
            #expect(built.entries.map(\.key) == planned.map(\.key), "plan order")
            #expect(built.entries.map(\.result) == [.updated, .failed, .rolledBack, .notConfirmed, .notStarted, .notStarted, .notStarted])
            #expect(UpdateRunResult.allCases.map(built.count).reduce(0, +) == 7)
            #expect(UpdateRunReport.Group.allCases.map { built.entries(in: $0).count }.reduce(0, +) == 7)
            #expect(built.plannedCount == 7)
            #expect(built.updatedCount == 1)
        }
    }

    @Test func theStatusNeverCallsAPartialRunFinished() {
        withLanguage(.pl) {
            let planned = [item("alpha", .cask), item("beta", .formula), item("gamma", .npm)]
            let alpha = outcome(planned[0], .succeeded)
            let beta = outcome(planned[1], .succeeded)
            let gamma = outcome(planned[2], .succeeded)

            let finished = report(planned, [alpha, beta, gamma])
            #expect(finished.status == .finished)
            #expect(finished.statusTitle == trp("Zaktualizowano %@ pakietów", 3))
            #expect(finished.namesNeedingAttention.isEmpty)

            let unconfirmed = report(planned, [alpha, outcome(planned[1], .notVerified), gamma])
            #expect(unconfirmed.status == .incomplete)
            #expect(unconfirmed.statusTitle == "Aktualizacja niekompletna")
            #expect(unconfirmed.namesNeedingAttention == ["beta"])

            let unattempted = report(planned, [alpha, beta])
            #expect(unattempted.status == .incomplete, "an item that produced no outcome was not updated")
            #expect(unattempted.namesNeedingAttention == ["gamma"])

            let stopped = report(planned, [alpha, beta, gamma], wasStopped: true)
            #expect(stopped.status == .stopped)
            #expect(stopped.statusTitle == "Aktualizacja przerwana")
        }
    }

    @Test func aPublisherChangeTheCheckDidNotConfirmIsNotUpdated() {
        withLanguage(.pl) {
            let cask = item("proton-mail", .cask)
            let changed = [outcome(cask, .publisherChanged(old: "AAA", new: "BBB"))]
            let sentence = trf(Self.changedSentence, "proton-mail", "AAA", "BBB")

            let stillListed = entry("proton-mail", in: report([cask], changed, stillOutdated: [cask.key]))
            #expect(stillListed?.result == .failed)
            #expect(stillListed?.checkAnswer == .stillListed)
            #expect(stillListed?.note(undo: nil) == sentence)
            #expect(stillListed?.offersPublisherTrust == true)

            let unanswered = entry("proton-mail", in: report([cask], changed, confirmed: false))
            #expect(unanswered?.result == .notConfirmed)
            #expect(unanswered?.checkAnswer == .unanswered)
            #expect(unanswered?.note(undo: nil) == sentence)
            #expect(unanswered?.offersPublisherTrust == true)

            let confirmed = entry("proton-mail", in: report([cask], changed))
            #expect(confirmed?.result == .updated)
            #expect(confirmed?.checkAnswer == .confirmed)
        }
    }

    @Test func theRunsOwnCaskOperationOwnsTheUndo() {
        let operation = UUID()
        let cask = item("alpha", .cask)
        let formula = item("beta", .formula)
        let bundle = URL(fileURLWithPath: "/Applications/Alpha.app")
        let ours = undoable("alpha", operationID: operation)
        let older = undoable("alpha", operationID: UUID())
        let built = report([cask, formula], [outcome(cask, .succeeded), outcome(formula, .succeeded)],
                           operationID: operation,
                           appPaths: ["alpha": bundle, "beta": URL(fileURLWithPath: "/Applications/Beta.app")])
        let withoutOperation = report([cask], [outcome(cask, .succeeded)])
        let alpha = entry("alpha", in: built)

        #expect(alpha.flatMap { built.undo(for: $0, in: [older, ours]) } == ours)
        #expect(alpha != nil && alpha.flatMap { built.undo(for: $0, in: [older]) } == nil,
                "another run's copy is not this run's undo")
        #expect(alpha != nil && alpha.flatMap { withoutOperation.undo(for: $0, in: [ours]) } == nil,
                "no cask operation, no undo")
        #expect(alpha?.appPath == bundle)
        #expect(entry("beta", in: built) != nil && entry("beta", in: built)?.appPath == nil,
                "only a cask carries the bundle the run prepared")
    }

    @Test func aRunStoppedAtTheZerothBoundaryReportsEveryItemAsStopped() {
        withLanguage(.pl) {
            let planned = [item("alpha", .cask), item("beta", .formula), item("gamma", .npm)]
            let built = report(planned, [], skipped: Set(planned.map(\.key)), wasStopped: true)

            #expect(built.entries.map { $0.note(undo: nil) } == Array(repeating: "zatrzymano przed startem", count: 3))
            #expect(built.status == .stopped)
            #expect(built.statusTitle == "Aktualizacja przerwana")
            #expect(built.updatedCount == 0)
            #expect(built.entries(in: .notStarted).count == 3)
        }
    }

    @Test func publisherChangesKeepTodaysWordsAndOfferTrustOnlyForCasks() {
        withLanguage(.pl) {
            let cask = item("proton-mail", .cask)
            let formula = item("tool", .formula)
            let rolledBack = item("signal", .cask)
            let blocked = item("figma", .cask)
            var built = report([cask, formula, rolledBack, blocked], [
                outcome(cask, .publisherChanged(old: "AAA", new: "BBB")),
                outcome(formula, .publisherChanged(old: "AAA", new: "BBB")),
                outcome(rolledBack, .publisherChangedAndRolledBack(old: "AAA", new: "CCC")),
                outcome(blocked, .publisherMismatchBeforeUpgrade(old: "AAA", current: "DDD")),
            ])
            let changed = entry("proton-mail", in: built)

            #expect(changed?.note(undo: nil) == trf(Self.changedSentence, "proton-mail", "AAA", "BBB"))
            #expect(changed?.offersPublisherTrust == true)
            #expect(changed?.reportedTeamID == "BBB")
            #expect(changed?.group == .needsAttention)
            #expect(changed?.result == .updated)
            #expect(entry("tool", in: built)?.offersPublisherTrust == false, "a formula has no publisher to trust")
            #expect(entry("signal", in: built)?.offersPublisherTrust == false, "a rolled-back change offers no trust")
            #expect(entry("figma", in: built)?.offersPublisherTrust == true)
            #expect(entry("figma", in: built)?.reportedTeamID == "DDD")
            #expect(built.unsettledPublisherChanges.map(\.name) == ["proton-mail", "tool", "signal", "figma"])

            built.settlePublisher(token: "proton-mail")
            let settled = entry("proton-mail", in: built)

            #expect(settled?.note(undo: nil) == "Zaufano nowemu podpisowi")
            #expect(settled?.offersPublisherTrust == false)
            #expect(built.unsettledPublisherChanges.map(\.name) == ["tool", "signal", "figma"])
        }
    }

    @Test func anUpdatedCaskShowsItsCopyOnlyWhenThisRunHasOne() {
        withLanguage(.pl) {
            let operation = UUID()
            let cask = item("alpha", .cask)
            let formula = item("beta", .formula)
            let docker = item("docker-desktop", .cask)
            let copy = undoable("alpha", operationID: operation)
            var built = report([cask, formula, docker], [cask, formula, docker].map { outcome($0, .succeeded) },
                               operationID: operation)
            let alpha = entry("alpha", in: built)

            #expect(alpha?.note(undo: alpha.flatMap { built.undo(for: $0, in: [copy]) })
                    == trf("kopia do %@", copy.expiresAt.formatted(date: .abbreviated, time: .omitted)))
            #expect(alpha?.note(undo: nil) == "bez cofnięcia")
            #expect(entry("beta", in: built)?.note(undo: nil) == "bez cofnięcia")
            #expect(entry("docker-desktop", in: built)?.note(undo: nil)
                    == "Pakiety zainstalowane. Gotowość silnika Docker nie była sprawdzana.")

            built.markUndone(token: "alpha", restoredVersion: "1.2")
            let undone = entry("alpha", in: built)
            let undo = undone.flatMap { built.undo(for: $0, in: [copy]) }

            #expect(undone != nil && undo == nil, "an undone item offers no second undo")
            #expect(undone?.note(undo: undo) == "cofnięto do 1.2")
        }
    }

    /// Wega's line in the summary is the run's, worded from its status: the three lines
    /// `report(run:)` says when the run ends, and nothing a later click or check says.
    @Test func aFinishedRunSaysItIsDone() {
        withLanguage(.pl) {
            let planned = [item("alpha", .cask), item("beta", .formula), item("gamma", .npm)]
            let finished = report(planned, planned.map { outcome($0, .succeeded) })
            #expect(finished.status == .finished)
            #expect(finished.wegaLine == trp("Gotowe! %@ pakietów odświeżonych.", 3))
        }
    }

    @Test func anIncompleteRunSaysSomePackagesDidNotUpdate() {
        withLanguage(.pl) {
            let planned = [item("alpha", .cask), item("beta", .formula)]
            let incomplete = report(planned, [outcome(planned[0], .succeeded), outcome(planned[1], .executionFailed)])
            #expect(incomplete.status == .incomplete)
            #expect(incomplete.wegaLine == "Część pakietów się nie zaktualizowała.")
        }
    }

    @Test func aStoppedRunSaysWegaStoppedIt() {
        withLanguage(.pl) {
            let planned = [item("alpha", .cask), item("beta", .formula)]
            let stopped = report(planned, [outcome(planned[0], .succeeded)], skipped: [planned[1].key], wasStopped: true)
            #expect(stopped.status == .stopped)
            #expect(stopped.wegaLine == "Przerwałam aktualizację.")
        }
    }

    @Test func wegasLineFollowsTheLanguageAfterTheReportIsBuilt() {
        let planned = [item("alpha", .cask), item("beta", .formula)]
        let finished = withLanguage(.pl) { report(planned, planned.map { outcome($0, .succeeded) }) }
        let incomplete = withLanguage(.pl) { report(planned, [outcome(planned[0], .succeeded)]) }
        let stopped = withLanguage(.pl) { report(planned, [], skipped: Set(planned.map(\.key)), wasStopped: true) }
        let polishDone = withLanguage(.pl) { trp("Gotowe! %@ pakietów odświeżonych.", 2) }

        withLanguage(.en) {
            #expect(finished.wegaLine == trp("Gotowe! %@ pakietów odświeżonych.", 2))
            #expect(finished.wegaLine != polishDone, "re-worded")
            #expect(incomplete.wegaLine == "Some packages didn't update.")
            #expect(stopped.wegaLine == "I stopped the update.")
        }
    }

    // MARK: - The mapping behind the success gate

    private struct Expected {
        let result: UpdateRunResult
        let group: UpdateRunReport.Group
        let note: String
    }

    private func entry(_ verdict: ItemUpdateVerdict?, kind: OutdatedItem.Kind = .formula,
                       skipped: Bool = false, answer: UpdateRunCheckAnswer = .confirmed) -> UpdateRunReportEntry {
        UpdateRunReportEntry(key: UpdatePlanner.key(name: "tool", kind: kind), name: "tool", kind: kind, from: "1", to: "2",
                             verdict: verdict, wasSkipped: skipped, checkAnswer: answer, appPath: nil,
                             undoneTo: nil, publisherSettled: false)
    }

    /// The row a verdict earns. A `switch` with no `default`: a new Core verdict does not compile
    /// until it has a row here.
    private func expected(_ verdict: ItemUpdateVerdict, answer: UpdateRunCheckAnswer = .confirmed) -> Expected {
        let changed = "%@: zmienił się podpis producenta (%@ → %@). Zaufaj nowemu podpisowi tylko wtedy, gdy producent zmienił konto."
        let restored = "%@: zmienił się podpis producenta (%@ → %@). Przywróciłam poprzednią zaufaną wersję."
        switch verdict {
        case .succeeded:
            return Expected(result: .updated, group: .updated, note: tr("bez cofnięcia"))
        case .publisherChanged(let old, let new):
            let result: UpdateRunResult = answer == .confirmed ? .updated : answer == .stillListed ? .failed : .notConfirmed
            return Expected(result: result, group: .needsAttention, note: trf(changed, "tool", old, new ?? "—"))
        case .publisherChangedAndRolledBack(let old, let new):
            return Expected(result: .rolledBack, group: .needsAttention, note: trf(restored, "tool", old, new ?? "—"))
        case .publisherMismatchBeforeUpgrade(let old, let current):
            return Expected(result: .notStarted, group: .notStarted, note: trf(
                "%@: podpis producenta już przed aktualizacją różnił się od zaufanego (%@ → %@). Aktualizację zablokowałam. Zaufaj nowemu podpisowi tylko wtedy, gdy producent zmienił konto.",
                "tool", old, current ?? "—"))
        case .notVerified:
            return Expected(result: .notConfirmed, group: .needsAttention, note: tr("zainstalowano, ale sprawdzenie nie potwierdziło wyniku"))
        case .stillOutdated:
            return Expected(result: .failed, group: .needsAttention, note: tr("nadal nieaktualna po sprawdzeniu"))
        case .rolledBack:
            return Expected(result: .rolledBack, group: .needsAttention, note: tr("nowa wersja nie przeszła kontroli — przywróciłam poprzednią"))
        case .executionFailed, .executionFailedAfterRollback:
            return Expected(result: .failed, group: .needsAttention, note: tr("nie udało się — szczegóły w logu"))
        case .executionFailedAfterPublisherRollback(let old, let new):
            return Expected(result: .failed, group: .needsAttention, note: trf(restored, "tool", old, new ?? "—"))
        case .executionFailedWithPublisherChange(let old, let new):
            return Expected(result: .failed, group: .needsAttention, note: trf(changed, "tool", old, new ?? "—"))
        case .rollbackFailed:
            return Expected(result: .failed, group: .needsAttention, note: trf(
                "%@: nowa wersja nie przeszła kontroli, a przywrócenie poprzedniej nie powiodło się. Sprawdź aplikację przed użyciem.", "tool"))
        }
    }

    /// Final review C3 — `status == .finished` rests on this mapping, so every Core verdict (and
    /// both ways of having none) is pinned here: its result, its group and its note, and an
    /// "Zaktualizowano" only where Core itself says the item is on the new version.
    @Test func everyVerdictMapsToOneResultGroupAndNote() {
        let verdicts: [ItemUpdateVerdict] = [
            .succeeded, .publisherChanged(old: "AAA", new: "BBB"), .publisherChangedAndRolledBack(old: "AAA", new: nil),
            .publisherMismatchBeforeUpgrade(old: "AAA", current: "CCC"), .notVerified, .stillOutdated, .rolledBack,
            .executionFailed, .executionFailedAfterRollback, .executionFailedAfterPublisherRollback(old: "AAA", new: "DDD"),
            .executionFailedWithPublisherChange(old: "AAA", new: "EEE"), .rollbackFailed,
        ]
        withLanguage(.pl) {
            var rows: [(UpdateRunReportEntry, Expected)] = verdicts.map { (entry($0), expected($0)) }
            let changed = ItemUpdateVerdict.publisherChanged(old: "AAA", new: "BBB")
            for answer in [UpdateRunCheckAnswer.stillListed, .unanswered] {
                rows.append((entry(changed, answer: answer), expected(changed, answer: answer)))
            }
            rows.append((entry(nil), Expected(result: .notStarted, group: .notStarted, note: tr("nie uruchomiłam — szczegóły w logu"))))
            rows.append((entry(nil, skipped: true), Expected(result: .notStarted, group: .notStarted, note: tr("zatrzymano przed startem"))))
            #expect(rows.count == 16, "twelve verdicts, two more check answers, two rows without a verdict")

            for (row, want) in rows {
                let context = "\(row.verdict.map { "\($0)" } ?? "nil"), \(row.checkAnswer), skipped \(row.wasSkipped)"
                #expect(row.result == want.result, "\(context)")
                #expect(row.group == want.group, "\(context)")
                #expect(row.note(undo: nil) == want.note, "\(context)")
                if row.result == .updated {
                    #expect(row.verdict?.upgraded == true, "\(context): only what Core calls upgraded is updated")
                }
            }
        }
    }

    // MARK: - Wega's ball

    /// Final review C4 — a confirmed changed publisher finishes the run, and its banner waits
    /// for the summary to close: until then the row in „Wymaga uwagi” is what holds the ball.
    @Test func aChangedPublisherHoldsWegasBallEvenInAFinishedRun() {
        let changed = item("proton-mail", .cask)
        let tool = item("tool", .formula)
        let finished = report([changed, tool], [outcome(changed, .publisherChanged(old: "AAA", new: "BBB")), outcome(tool, .succeeded)])
        #expect(finished.status == .finished, "sanity: the check confirmed both")
        #expect(finished.holdsAttention, "a possible takeover sits in „Wymaga uwagi”")

        #expect(!report([tool], [outcome(tool, .succeeded)]).holdsAttention, "a clean run lets the ball go")
        #expect(report([tool], [outcome(tool, .executionFailed)]).holdsAttention)
        #expect(report([tool], [], skipped: [tool.key], wasStopped: true).holdsAttention)
    }

    // MARK: - The failure log

    /// Final review C1 — the failure log names what the summary shows as not updated. A planned
    /// row nothing attempted and a changed publisher the check did not confirm are not in
    /// `summary.notUpgraded`, so the headline used to blame Homebrew with no item named.
    @Test func theFailureLogNamesEveryItemTheSummaryShowsAsNotUpdated() {
        let planned = [item("alpha", .formula), item("journal", .cask), item("stopped", .formula), item("proton-mail", .cask),
                       item("figma", .cask), item("Pages", .appStore), item("wget", .formula)]
        let built = report(planned, [
            outcome(planned[0], .succeeded),
            outcome(planned[3], .publisherChanged(old: "AAA", new: "BBB")),
            outcome(planned[4], .publisherChanged(old: "AAA", new: "CCC")),
            outcome(planned[6], .executionFailed),
        ], skipped: [planned[2].key], stillOutdated: [planned[3].key])

        #expect(built.failureLogHeadline == "Aktualizacja niekompletna: journal, stopped, proton-mail, Pages, wget")
        #expect(!built.failureLogHeadline.contains("Brew zgłosił błąd"))
        #expect(built.failureLogLinesBeyondTheSummary == [
            "journal: nie uruchomiono — żaden etap aktualizacji nie objął tej pozycji",
            "stopped: zatrzymano przed startem",
            "proton-mail: zaktualizowano, ale zmienił się Team ID wydawcy — nadal widnieje jako nieaktualne po skanie kontrolnym",
            "Pages: nie uruchomiono — żaden etap aktualizacji nie objął tej pozycji",
        ], "wget's line is the summary's own per-outcome line; figma was confirmed")

        let changed = item("proton-mail", .cask)
        let unanswered = report([changed], [outcome(changed, .publisherChanged(old: "AAA", new: "BBB"))],
                                confirmed: false)
        #expect(unanswered.failureLogHeadline == "Aktualizacja niekompletna: proton-mail")
        #expect(unanswered.failureLogLinesBeyondTheSummary == [
            "proton-mail: zaktualizowano, ale zmienił się Team ID wydawcy — skan po aktualizacji nie potwierdził wyniku",
        ])
    }

    @Test func notesFollowTheLanguageAfterTheReportIsBuilt() {
        let failed = item("beta", .formula)
        let built = withLanguage(.pl) { report([failed], [outcome(failed, .executionFailed)]) }

        let english = withLanguage(.en) { (entry("beta", in: built)?.note(undo: nil), built.statusTitle) }

        #expect(english.0 == "failed — details in the log")
        #expect(english.1 == "Update incomplete")
    }
}
