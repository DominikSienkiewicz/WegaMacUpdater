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
        #expect(view[start..<end].components(separatedBy: "HiddenByRulesRow(").count == 3,
                "under the last group and under the empty state")
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
        #expect(closed == 1, "a replaced toast must not close the one that replaced it")
    }

    /// The countdown hangs on the callout the toast draws, so hosting the toast starts it — a
    /// modifier on a container that may be empty never would.
    @Test func aHostedToastStartsItsCountdown() async throws {
        var slept: Duration?
        var closed = false
        let toast = RuleUndoToast(
            notice: RuleUndoNotice(id: UUID(), message: "Slack", key: "c:slack", previous: nil),
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
