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
        stillOutdated: Set<String> = [], confirmed: Set<OutdatedItem.Kind> = [.formula, .cask, .appStore, .npm]
    ) -> UpdateRunReport {
        UpdateRunReport.make(
            planned: planned,
            summary: UpdateRunSummary(items: outcomes, diagnostics: [], needsSudoPassword: false),
            skippedKeys: skipped, wasStopped: wasStopped,
            startedAt: nil, finishedAt: Self.finishedAt,
            caskOperationID: operationID, caskAppPaths: appPaths,
            stillOutdatedKeys: stillOutdated, confirmedKinds: confirmed
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

            let unanswered = entry("proton-mail", in: report([cask], changed, confirmed: [.formula, .appStore, .npm]))
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

    @Test func notesFollowTheLanguageAfterTheReportIsBuilt() {
        let failed = item("beta", .formula)
        let built = withLanguage(.pl) { report([failed], [outcome(failed, .executionFailed)]) }

        let english = withLanguage(.en) { (entry("beta", in: built)?.note(undo: nil), built.statusTitle) }

        #expect(english.0 == "failed — details in the log")
        #expect(english.1 == "Update incomplete")
    }
}
