import AppKit
import Foundation
import MacUpdaterCore
import SwiftUI
import Testing
import WegaTestSupport
@testable import WegaMacUpdater

/// UXP-11 — "Nie aktualizuj" and "Pomiń tę wersję" used to make a row vanish with no way back
/// from the list. Now the change offers "Cofnij" at once, and the list says how many of the
/// user's rules hide something from this scan. Neither undo nor "Przywróć" adds to the queue.
@Suite("Hidden by rules") @MainActor
struct HiddenRulesTests {
    private enum StubError: Error {
        case unexpected([String])
    }

    @Test func hidingAnUpdateOffersUndoAndCountsTheRule() throws {
        let (store, item) = try storeWithOneFormula()
        defer { UpdatePolicyStore.shared.remove(key: item.policyKey) }
        store.selected = [item.key]
        store.ignoreItem(item)
        #expect(store.ruleUndo?.message == trf("Nie będę proponować aktualizacji %@.", item.name))
        #expect(store.rulesHidingResults.map(\.key) == [item.policyKey])
        store.undoRuleChange()
        #expect(UpdatePolicyStore.shared.policy(for: item.policyKey) == nil)
        #expect(store.rulesHidingResults.isEmpty && store.ruleUndo == nil)
        #expect(store.allItems.contains { $0.key == item.key })
        #expect(!store.selected.contains(item.key), "undo restores the row, never the queue")
    }

    @Test func undoingASkipRestoresTheRuleThatWasThereBefore() throws {
        let (store, item) = try storeWithOneFormula()
        defer { UpdatePolicyStore.shared.remove(key: item.policyKey) }
        UpdatePolicyStore.shared.pin(key: item.policyKey, name: item.name, version: "9")
        store.skipItem(item)
        #expect(store.ruleUndo?.message == trf("Pominęłam wersję %@ aplikacji %@. Następną pokażę.", item.to ?? "", item.name))
        store.undoRuleChange()
        #expect(UpdatePolicyStore.shared.policy(for: item.policyKey) == .pinned(version: "9"))
    }

    @Test func restoreWritesTheEntryBack() {
        let (defaults, teardown) = TestDefaults.isolated("ux-review-next-rules")
        defer { teardown() }
        let policies = UpdatePolicyStore(defaults: defaults)
        policies.restore(UpdatePolicyEntry(key: "c:zoom", displayName: "Zoom", policy: .ignored))
        #expect(UpdatePolicyStore(defaults: defaults).policy(for: "c:zoom") == .ignored)
    }

    @Test func copyInBothLanguages() {
        withLanguage(.en) {
            #expect(trf("Nie będę proponować aktualizacji %@.", "Slack") == "I won't offer updates for Slack.")
            #expect(trf("Pominęłam wersję %@ aplikacji %@. Następną pokażę.", "4.2", "Slack") == "Skipped version 4.2 of Slack. I'll show the next one.")
            #expect(trf("Ukryte przez Twoje reguły: %@ · Pokaż", "3") == "Hidden by your rules: 3 · Show")
            #expect(tr("Przywróć") == "Restore")
        }
    }

    @Test func theRowSurvivesAnEmptyListAndTheToastCountsDownOnItself() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let start = try #require(view.range(of: "private var listColumn: some View")).upperBound
        let end = try #require(view.range(of: "private var planSheet: some View", range: start..<view.endIndex)).lowerBound
        #expect(view[start..<end].components(separatedBy: "HiddenByRulesRow(").count == 4,
                "under the last group, under the empty state and under an empty category")
        #expect(view.contains("RuleUndoToast(notice:"))
        let rules = try source("Sources/MacUpdater/PolicyRules.swift")
        let toast = try #require(rules.range(of: "struct RuleUndoToast: View")).upperBound
        #expect(rules[toast...].prefix(900).contains(".task(id: notice.id)"))
        #expect(!rules[toast...].prefix(900).contains("Group {"))
        #expect(RuleUndoToast.lifetime == .seconds(8))
        #expect(try source("Sources/MacUpdater/InfoView.swift").contains("PolicyRulesList("))
    }

    // MARK: - Beyond the brief's cases

    /// The manual list goes through the same rules, so its hidden rows count and come back too.
    @Test func hidingAManualAppCountsItsRuleAndUndoBringsItBack() throws {
        let (store, _) = try storeWithOneFormula()
        let app = ManualOutdatedApp(
            name: "Hidden Manual",
            path: URL(fileURLWithPath: "/Applications/Hidden-\(UUID().uuidString).app"),
            installedVersion: "1",
            availableVersion: "2",
            source: .sparkle,
            bundleIdentifier: "example.hidden.\(UUID().uuidString)"
        )
        store.manualOutdated = [app]
        defer { UpdatePolicyStore.shared.remove(key: app.policyKey) }
        UpdatePolicyStore.shared.pin(key: app.policyKey, name: app.name, version: "9")
        #expect(store.rulesHidingResults.isEmpty, "a pin the offer stays under hides nothing")

        store.ignoreManual(app)
        #expect(store.ruleUndo?.message == trf("Nie będę proponować aktualizacji %@.", app.name))
        #expect(store.rulesHidingResults.map(\.key) == [app.policyKey])
        #expect(!store.visibleManual.contains { $0.policyKey == app.policyKey })

        store.undoRuleChange()
        #expect(UpdatePolicyStore.shared.policy(for: app.policyKey) == .pinned(version: "9"))
        #expect(store.visibleManual.contains { $0.policyKey == app.policyKey })
        #expect(store.rulesHidingResults.isEmpty)
    }

    /// A skip that writes nothing (the source names no version) has nothing to take back.
    @Test func aSkipThatWritesNothingOffersNoUndo() throws {
        let (store, _) = try storeWithOneFormula()
        let noVersion = OutdatedItem(key: "f:no-version-\(UUID().uuidString)", name: "No Version", from: "1", to: nil, kind: .formula)
        store.skipItem(noVersion)
        #expect(store.ruleUndo == nil)
        #expect(UpdatePolicyStore.shared.policy(for: noVersion.policyKey) == nil)
    }

    /// The toast's countdown, with its sleep injected: it closes after its lifetime, and a
    /// countdown cancelled first (the toast was replaced or closed) closes nothing.
    @Test func theToastClosesOnlyAfterItsLifetime() async {
        var slept: [Duration] = []
        var closed = 0
        await RuleUndoToast.countDown(RuleUndoToast.lifetime, sleep: { slept.append($0) }, then: { closed += 1 })
        #expect(slept == [.seconds(8)])
        #expect(closed == 1)

        await RuleUndoToast.countDown(RuleUndoToast.lifetime, sleep: { _ in throw CancellationError() }, then: { closed += 1 })
        #expect(closed == 1, "a countdown whose sleep was cancelled closes nothing")
    }

    /// The other half of cancellation: the sleep ends normally, but the toast was replaced or
    /// closed meanwhile. The task created here is cancelled before it ever runs.
    @Test func aCountdownCancelledBeforeItsSleepEndsClosesNothing() async {
        let closed = Counter()
        let countdown = Task { @MainActor in
            await RuleUndoToast.countDown(RuleUndoToast.lifetime, sleep: { _ in }, then: { closed.value += 1 })
        }
        countdown.cancel()
        await countdown.value
        #expect(closed.value == 0)
    }

    // MARK: - Fix round 1

    /// M1 — closing is by id: the countdown or the close button of a toast that has since
    /// been replaced leaves the newer toast on screen.
    @Test func anOlderToastNeverClosesANewerOne() throws {
        let (store, item) = try storeWithOneFormula()
        let other = OutdatedItem(key: "f:other-\(UUID().uuidString)", name: "Other", from: "1", to: "2", kind: .formula)
        defer { [item.policyKey, other.policyKey].forEach(UpdatePolicyStore.shared.remove(key:)) }
        store.ignoreItem(item)
        let older = try #require(store.ruleUndo).id
        store.ignoreItem(other)
        let newer = try #require(store.ruleUndo).id

        store.dismissRuleUndo(id: older)
        #expect(store.ruleUndo?.id == newer)
        store.dismissRuleUndo(id: newer)
        #expect(store.ruleUndo == nil)
        #expect(try source("Sources/MacUpdater/UpdateView.swift").contains("onClose: { scan.dismissRuleUndo(id: notice.id) }"))
    }

    /// M4 — "Przywróć", in the sheet or in Settings, removes the rule a toast would undo; the
    /// toast goes with it, so "Cofnij" cannot put the change's `previous` back afterwards.
    @Test func restoringTheRuleByHandClosesItsToast() throws {
        let (store, item) = try storeWithOneFormula()
        let unrelated = "f:unrelated-\(UUID().uuidString)"
        defer { [item.policyKey, unrelated].forEach(UpdatePolicyStore.shared.remove(key:)) }
        UpdatePolicyStore.shared.pin(key: item.policyKey, name: item.name, version: "9")
        store.skipItem(item)

        UpdatePolicyStore.shared.ignore(key: unrelated, name: "Unrelated")
        #expect(store.ruleUndo?.key == item.policyKey, "another key's rule leaves the toast alone")

        UpdatePolicyStore.shared.remove(key: item.policyKey)
        #expect(store.ruleUndo == nil)
        store.undoRuleChange()
        #expect(UpdatePolicyStore.shared.policy(for: item.policyKey) == nil, "the old pin does not come back")
    }

    /// M2, M3, M6 and M8, where the source is the only witness.
    @Test func theSheetClosesAfterTheLastRestoreAndTheRowIsOneTarget() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let start = try #require(view.range(of: "private var listColumn: some View")).upperBound
        let end = try #require(view.range(of: "private var planSheet: some View", range: start..<view.endIndex)).lowerBound
        #expect(view[start..<end].components(separatedBy: "scan.rulesHidingResults").count == 2,
                "the hidden rules are counted once per list, not once per use")
        let rules = try source("Sources/MacUpdater/PolicyRules.swift")
        let sheet = try #require(rules.range(of: "struct PolicyRulesSheet: View"))
        let sheetEnd = try #require(rules.range(of: "struct HiddenByRulesRow: View", range: sheet.upperBound..<rules.endIndex))
        let sheetSource = rules[sheet.upperBound..<sheetEnd.lowerBound]
        #expect(sheetSource.contains(".onChange(of: entries.isEmpty)"))
        #expect(sheetSource.contains("dismiss()"))
        #expect(!sheetSource.contains("Group {"))
        let row = try #require(rules.range(of: "struct HiddenByRulesRow: View")).upperBound
        let rowEnd = try #require(rules.range(of: "struct RuleUndoToast: View", range: row..<rules.endIndex)).lowerBound
        #expect(rules[row..<rowEnd].contains(".contentShape(Rectangle())"), "the whole row is the button, gaps included")
    }

    /// M7 — the narrow (388 pt) and compact (480 pt) list widths, in Polish and English, with
    /// the longest line each view carries: the text wraps instead of being cut, and "Cofnij",
    /// the close button and the row's chevron stay inside the column.
    @Test(arguments: [CGFloat(388), 480])
    func theToastAndTheRowFitTheNarrowestList(width: CGFloat) {
        for language in [AppLanguage.pl, .en] {
            withLanguage(language) {
                let message = trf("Pominęłam wersję %@ aplikacji %@. Następną pokażę.", "10.13.2", "Microsoft Remote Desktop Beta")
                let notice = RuleUndoNotice(
                    id: UUID(), message: message, key: "k",
                    previous: nil, written: UpdatePolicyEntry(key: "k", displayName: "k", policy: .ignored)
                )
                expectTextFits(RuleUndoToast(notice: notice, onUndo: {}, onClose: {}),
                               text: message, font: .wega(.callout, weight: .semibold),
                               width: width, label: "toast, \(language), \(width) pt")
                expectTextFits(HiddenByRulesRow(count: 22, onShow: {}),
                               text: trf("Ukryte przez Twoje reguły: %@ · Pokaż", "22"), font: .wega(.subheadline),
                               width: width, label: "row, \(language), \(width) pt")
            }
        }
    }

    /// The countdown hangs on the callout the toast draws, so hosting the toast starts it — a
    /// modifier on a container that may be empty never would.
    @Test func aHostedToastStartsItsCountdown() async throws {
        var slept: Duration?
        var closed = false
        let toast = RuleUndoToast(
            notice: RuleUndoNotice(id: UUID(), message: "Slack", key: "c:slack", previous: nil,
                                   written: UpdatePolicyEntry(key: "c:slack", displayName: "Slack", policy: .ignored)),
            onUndo: {},
            onClose: { closed = true },
            sleep: { slept = $0 }
        )
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 420, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: toast.frame(width: 420))
        window.orderFrontRegardless()

        let deadline = Date().addingTimeInterval(5)
        while !closed, Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            pumpMainRunLoop(for: 0.02)
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(slept == RuleUndoToast.lifetime)
        #expect(closed, "the toast never closed itself")
    }

    // MARK: - Helpers

    @MainActor private final class Counter {
        var value = 0
    }

    /// Lays `view` out `width` wide and checks that nothing in it is pushed past that width and
    /// that it is tall enough for `text` wrapped in the width the rest of the view leaves it.
    private func expectTextFits(_ view: some View, text: String, font: Font, width: CGFloat, label: String) {
        let fitted = NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let others = NSHostingView(rootView: view.fixedSize()).fittingSize.width
            - NSHostingView(rootView: Text(verbatim: text).font(font).fixedSize()).fittingSize.width
        let needed = NSHostingController(rootView: Text(verbatim: text).font(font))
            .sizeThatFits(in: CGSize(width: width - others, height: .greatestFiniteMagnitude)).height
        #expect(fitted.width <= width, "\(label): needs \(fitted.width) pt, so a control is pushed out")
        #expect(fitted.height + 0.5 >= needed, "\(label): \(fitted.height) pt tall, the text needs \(needed) pt")
    }

    /// A store whose scan found one formula, named with a UUID so its policy key collides with
    /// no other suite's — `ScanStore` reads `UpdatePolicyStore.shared`.
    private func storeWithOneFormula() throws -> (ScanStore, OutdatedItem) {
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        let name = "hidden-rules-\(UUID().uuidString)"
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: name, installedVersions: ["1"], currentVersion: "2")],
            casks: []
        )
        let item = try #require(harness.store.allItems.first { $0.name == name })
        return (harness.store, item)
    }

    /// One turn of the main run loop, so the hosted view lays out and starts its task.
    /// Synchronous on purpose: `RunLoop.run(until:)` is unavailable from async contexts.
    private func pumpMainRunLoop(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
