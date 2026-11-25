import Combine
import Foundation
import MacUpdaterCore
import Testing
import WegaTestSupport

@testable import WegaMacUpdater

/// C2 stage 4 — a window run ends in a report instead of result banners. The report opens on
/// every path that reports a run, closes through one door, and only the banners a button fixes
/// (and the failed rollback) are still raised; a changed publisher waits in the report and comes
/// back as today's sticky banner when the report closes unresolved.
@Suite("Run report in the store") @MainActor
struct RunReportStoreTests {
    private enum StubError: Error { case unexpected([String]) }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let appURL = URL(fileURLWithPath: "/TestApplications/Proton Mail.app")
    private static let publisherTitle = "Zmienił się podpis producenta"

    private final class ActivityRecorder {
        var activities: [UpdateActivity] = []
        var wegaLines: [String] = []
    }

    /// A store with a lock, a clock, defaults and ledgers of its own, and a check that answered
    /// for every source, so nothing here writes the app's shared state.
    private func makeStore(
        defaults: UserDefaults,
        configure: (inout ScanStoreDependencies) -> Void = { _ in }
    ) -> (store: ScanStore, announcer: RecordingAnnouncer) {
        let operations = OperationCoordinator()
        var dependencies = ScanStoreDependencies(
            operations: operations, upgrades: UpgradeCoordinator(operations: operations),
            caskAppPathResolver: CaskAppPathResolver(), bundleExists: { _ in true },
            manualScan: { _, _ in ([], 0) }, reportWindowScan: { _, _, _ in },
            recordUpdateRun: { _ in }, settleAppManagementPermission: { _ in }, undoableUpdates: { [] }
        )
        dependencies.upgradeMutex = UpgradeMutex()
        dependencies.now = { Self.now }
        dependencies.defaults = defaults
        dependencies.teamIDLedger = TeamIDLedger(defaults: defaults)
        dependencies.rollbackLedger = CaskRollbackLedger(defaults: defaults)
        configure(&dependencies)
        let announcer = RecordingAnnouncer()
        let store = ScanStore(
            resultStore: ScanResultStore(io: ScanStoreRuntimeSnapshotIO()),
            runningApplicationInspector: ScanStoreRuntimeApplicationInspector(),
            dependencies: dependencies,
            announcer: announcer
        )
        store.confirmedSourceKinds = [.formula, .cask, .appStore, .npm]
        return (store, announcer)
    }

    private func cask(_ name: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: .cask), name: name, from: "1", to: "2", kind: .cask)
    }

    private func formula(_ name: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: .formula), name: name, from: "1", to: "2", kind: .formula)
    }

    private func succeeded(_ items: [OutdatedItem]) -> UpdateRunOutcome {
        var run = UpdateRunOutcome()
        run.record(items, outcome: BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: []))
        return run
    }

    private func validated(_ item: OutdatedItem, _ verdict: CaskValidationVerdict) -> UpdateRunOutcome {
        var run = succeeded([item])
        run.applyValidation([item.name: verdict])
        return run
    }

    private func publisherChanged(_ item: OutdatedItem) -> UpdateRunOutcome {
        validated(item, .publisherChanged(old: "AAA", new: "BBB"))
    }

    private func failed(_ item: OutdatedItem, sudo: Bool = false, appManagement: Bool = false) -> UpdateRunOutcome {
        var run = UpdateRunOutcome()
        run.record([item], outcome: BrewUpgradeOutcome(
            exitCode: 1, failedTokens: [item.name], errorLines: ["Error: \(item.name): install failed"],
            requiresSudoPassword: sudo, requiresAppManagementPermission: appManagement
        ))
        return run
    }

    /// Every banner the store holds, sticky ones first, emptying the queue.
    private func drainBanners(_ store: ScanStore) -> [BannerData] {
        var drained: [BannerData] = []
        while let banner = store.banner {
            drained.append(banner)
            store.dismissBanner()
        }
        return drained
    }

    private func publisherBanners(_ store: ScanStore) -> [BannerData] {
        drainBanners(store).filter { $0.title == Self.publisherTitle }
    }

    private static func refusingRunner() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner(
            run: { throw StubError.unexpected($0.arguments) },
            events: { .failure(StubError.unexpected($0.arguments)) }
        )
    }

    private static func quietScanRunner() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner(run: { request in
            switch request.arguments {
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
            case ["outdated", "-g", "--json"]:
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            default:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        })
    }

    private struct ZerothStop {
        let store: ScanStore
        let keys: Set<String>
        let watch: AnyCancellable
    }

    /// A store with two outdated formulae whose run is stopped the moment its board opens: the
    /// zeroth boundary, before any tool starts.
    private func storeStoppingAtTheZerothBoundary(runner: ScanStoreRuntimeProcessRunner) -> ZerothStop {
        let store = makeScanStoreRuntimeHarness(runner: runner).store
        store.brewOutdated = BrewOutdated(formulae: [
            BrewOutdatedItem(name: "stop-one-\(UUID().uuidString)", installedVersions: ["1"], currentVersion: "2"),
            BrewOutdatedItem(name: "stop-two-\(UUID().uuidString)", installedVersions: ["1"], currentVersion: "2"),
        ], casks: [])
        let watch = store.$runBoard.sink { board in
            if board.startedAt != nil, !store.updateInterruption.isRequested { store.cancelUpdate() }
        }
        return ZerothStop(store: store, keys: Set(store.allItems.map(\.key)), watch: watch)
    }

    // MARK: - Opening the report instead of result banners

    @Test func aFinishedRunOpensTheReportAndRaisesNoResultBanner() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-finished")
        defer { teardown() }
        let store = makeStore(defaults: defaults).store
        let planned = [cask("alpha"), cask("beta")]

        withLanguage(.pl) {
            store.report(run: succeeded(planned), planned: planned)
            let titles = drainBanners(store).map(\.title)

            #expect(store.runReport?.entries.count == 2)
            #expect(store.runReport?.status == .finished)
            #expect(!titles.contains { $0.hasPrefix("Zaktualizowano") }, "\(titles)")
            #expect(titles.isEmpty, "\(titles)")
            #expect(defaults.bool(forKey: ReadinessPresentation.dismissedKey), "a finished run still settles the readiness card")
        }
    }

    @Test func aFailedRunRaisesNoGenericBannerButKeepsTheActionableOnes() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-failed")
        defer { teardown() }
        let item = formula("broken")

        withLanguage(.pl) {
            let plain = makeStore(defaults: defaults).store
            plain.report(run: failed(item), planned: [item])
            #expect(drainBanners(plain).isEmpty, "the summary says it; no generic „Aktualizacja niekompletna”")
            #expect(plain.runReport?.entries.map(\.result) == [.failed])

            let sudo = makeStore(defaults: defaults).store
            sudo.report(run: failed(item, sudo: true), planned: [item])
            let sudoBanners = drainBanners(sudo)
            #expect(sudoBanners.map(\.title) == ["Aktualizacja niekompletna"])
            #expect(sudoBanners.first?.variant == .danger)
            #expect(sudoBanners.first?.action == .openSettings)

            let permission = makeStore(defaults: defaults).store
            permission.report(run: failed(item, appManagement: true), planned: [item])
            let permissionBanners = drainBanners(permission)
            #expect(permissionBanners.map(\.title) == ["Brak uprawnienia „Zarządzanie aplikacjami”"])
            #expect(permissionBanners.first?.action == .openAppManagementSettings)
        }
    }

    @Test func aStoppedRunRaisesNoInterruptedBanner() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-stopped")
        defer { teardown() }
        let store = makeStore(defaults: defaults).store
        let done = formula("done")
        let skipped = formula("skipped")
        store.updating = true
        store.cancelUpdate()
        #expect(store.shouldStopUpdate(before: [skipped.key]))
        store.updating = false

        withLanguage(.pl) {
            store.report(run: succeeded([done]), planned: [done, skipped])

            #expect(drainBanners(store).isEmpty, "no „Aktualizacja przerwana” banner")
            #expect(store.runReport?.status == .stopped)
            #expect(store.runReport?.entries.last?.note(undo: nil) == "zatrzymano przed startem")
        }
    }

    /// Final review C6 — the stop is announced in the summary's own counts, as a finished run is:
    /// the skipped row is one of the planned ones, not a row that never existed.
    @Test func aStoppedRunIsAnnouncedInTheSummarysCounts() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-stopped-announcement")
        defer { teardown() }
        let (store, announcer) = makeStore(defaults: defaults)
        let done = formula("done")
        let skipped = formula("skipped")
        store.updating = true
        store.cancelUpdate()
        #expect(store.shouldStopUpdate(before: [skipped.key]))
        store.updating = false

        withLanguage(.pl) {
            store.report(run: succeeded([done]), planned: [done, skipped])
            #expect(announcer.texts.last == AnnouncementCopy.runStopped(updated: 1, total: 2), "\(announcer.texts)")
            #expect(store.runReport.map { AnnouncementCopy.runStopped(updated: $0.updatedCount, total: $0.plannedCount) }
                    == announcer.texts.last)
        }
    }

    /// Final review C5 — the check confirms a run all or nothing, as Core's `applyRescan` does: with
    /// npm unanswered the npm package is unconfirmed, and so is a changed publisher's cask, even
    /// though the cask source answered.
    @Test func aChangedPublisherIsConfirmedOnlyWhenTheWholeCheckIs() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-all-or-nothing")
        defer { teardown() }
        let store = makeStore(defaults: defaults).store
        store.confirmedSourceKinds = [.formula, .cask, .appStore]
        let changed = cask("proton-mail")
        let tool = OutdatedItem(key: UpdatePlanner.key(name: "tool", kind: .npm), name: "tool", from: "1", to: "2", kind: .npm)
        var run = publisherChanged(changed)
        run.record([tool], outcome: BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: []))
        let confirmed = Set([changed, tool].map(\.kind)).isSubset(of: store.confirmedSourceKinds)
        run.applyRescan(stillOutdatedKeys: [], confirmed: confirmed)

        withLanguage(.pl) {
            store.report(run: run, planned: [changed, tool])
        }

        #expect(!confirmed, "sanity: npm did not answer")
        #expect(store.runReport?.entries.map(\.result) == [.notConfirmed, .notConfirmed],
                "under-report: nothing the check could not confirm is „Zaktualizowano”")
        #expect(store.runReport?.status == .incomplete)
    }

    @Test func aRunStoppedAtTheZerothBoundaryReportsEveryItemAsStopped() async {
        let runner = Self.refusingRunner()
        let stop = storeStoppingAtTheZerothBoundary(runner: runner)
        defer { stop.watch.cancel() }
        let store = stop.store
        let keys = stop.keys
        let recorder = ActivityRecorder()
        store.bind(ScanSinks(wegaState: { recorder.wegaLines.append($0.line) },
                             activity: { recorder.activities.append($0) }))

        await withLanguage(.pl) { await store.runUpdate(targetKeys: keys) }

        #expect(runner.requests.isEmpty, "no tool was started")
        #expect(store.runReport?.status == .stopped)
        #expect(Set(store.runReport?.entries.map(\.key) ?? []) == keys)
        withLanguage(.pl) {
            #expect(store.runReport?.entries.map { $0.note(undo: nil) } == ["zatrzymano przed startem", "zatrzymano przed startem"])
            #expect(store.runReport?.statusTitle == "Aktualizacja przerwana")
            // A clean stop stays a stop: an empty summary has `allItemsUpgraded`, and without the
            // guard after the success path the run would fall into the failure branch.
            #expect(!recorder.activities.contains(.error), "\(recorder.activities)")
            #expect(recorder.activities.last == .idle, "\(recorder.activities)")
            #expect(recorder.wegaLines.last == tr("Przerwałam aktualizację."), "\(recorder.wegaLines)")
        }
        #expect(store.banner == nil)
    }

    @Test func theRollbackFailureBannerStays() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-rollback-failed")
        defer { teardown() }
        let store = makeStore(defaults: defaults).store
        let item = cask("signal")

        withLanguage(.pl) {
            store.report(run: validated(item, .rollbackFailed), planned: [item])
            store.showBanner(BannerData(variant: .success, title: "later", message: "transient"))

            #expect(store.banner?.title == "Nie udało się cofnąć aktualizacji", "sticky: ahead of a later transient banner")
            #expect(store.banner?.variant == .danger)
            #expect(store.banner?.action == .openLogs)
            #expect(store.runReport?.entries.map(\.result) == [.failed])
        }
    }

    @Test func aRunWithAnUnattemptedItemIsNotASuccess() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-unattempted")
        defer { teardown() }
        let (store, announcer) = makeStore(defaults: defaults)
        let recorder = ActivityRecorder()
        store.bind(ScanSinks(activity: { recorder.activities.append($0) }))
        let planned = [formula("one"), formula("two"), cask("slack")]

        withLanguage(.pl) {
            store.report(run: succeeded(Array(planned.prefix(2))), planned: planned)

            #expect(store.runReport?.status == .incomplete)
            #expect(!recorder.activities.contains(.success), "\(recorder.activities)")
            #expect(defaults.object(forKey: ReadinessPresentation.dismissedKey) == nil)
            #expect(announcer.texts.last == AnnouncementCopy.runFinished(updated: 2, total: 3, needsAttention: ["slack"]))
        }
    }

    // MARK: - Closing it through one door

    @Test func aPublisherChangeWaitsInTheReportAndReturnsWhenItCloses() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-publisher")
        defer { teardown() }
        let store = makeStore(defaults: defaults).store
        let item = cask("proton-mail")

        withLanguage(.pl) {
            store.report(run: publisherChanged(item), planned: [item])
            #expect(publisherBanners(store).isEmpty, "the report carries it while it is open")
            #expect(store.runReport?.entries.first?.offersPublisherTrust == true)

            store.closeRunReport()
            store.showBanner(BannerData(variant: .success, title: "later", message: "transient"))
            #expect(store.banner?.title == Self.publisherTitle, "sticky: ahead of a later transient banner")
            let returned = publisherBanners(store)

            #expect(store.runReport == nil)
            #expect(returned.count == 1)
            #expect(returned.first?.variant == .danger)
            #expect(returned.first?.action == .trustPublisher(token: "proton-mail", teamID: "BBB"))
            #expect(returned.first?.message == trf(
                "%@: zmienił się podpis producenta (%@ → %@). Zaufaj nowemu podpisowi tylko wtedy, gdy producent zmienił konto.",
                "proton-mail", "AAA", "BBB"))

            store.closeRunReport()
            #expect(store.banner == nil, "a second close raises nothing")
        }
    }

    @Test func aSettledPublisherChangeDoesNotReturn() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-settled")
        defer { teardown() }
        let store = makeStore(defaults: defaults).store
        let item = cask("proton-mail")

        withLanguage(.pl) {
            store.report(run: publisherChanged(item), planned: [item])
            store.settleRunReportPublisher(token: "proton-mail")

            #expect(store.runReport?.entries.first?.publisherSettled == true)
            store.closeRunReport()
            #expect(drainBanners(store).isEmpty)
        }
    }

    @Test func startingAScanClosesTheReport() async {
        let store = makeScanStoreRuntimeHarness(runner: Self.quietScanRunner()).store
        let item = cask("scan-door-\(UUID().uuidString)")
        withLanguage(.pl) { store.report(run: publisherChanged(item), planned: [item]) }
        _ = drainBanners(store)

        withLanguage(.pl) { store.startCheck(refreshesCatalog: false) }
        let scan = store.scanTask
        let returned = publisherBanners(store)
        store.cancelScan()
        await scan?.value

        #expect(scan != nil, "sanity: the scan started")
        #expect(store.runReport == nil)
        #expect(returned.count == 1, "a scan closes the summary through the one door")
    }

    @Test func theNextRunClosesTheReportBeforeItStarts() async {
        let stop = storeStoppingAtTheZerothBoundary(runner: Self.refusingRunner())
        defer { stop.watch.cancel() }
        let store = stop.store
        let keys = stop.keys
        let item = cask("run-door-\(UUID().uuidString)")
        withLanguage(.pl) { store.report(run: publisherChanged(item), planned: [item]) }
        _ = drainBanners(store)

        await withLanguage(.pl) { await store.runUpdate(targetKeys: keys) }

        #expect(publisherBanners(store).count == 1, "the next run closes the summary through the one door")
        #expect(Set(store.runReport?.entries.map(\.key) ?? []) == keys, "the open report is the new run's")
    }

    @Test(arguments: [false, true])
    func aCancelledTrustAlertSettlesNothing(confirms: Bool) async {
        let (defaults, teardown) = TestDefaults.isolated("run-report-trust")
        defer { teardown() }
        let store = makeStore(defaults: defaults) { dependencies in
            dependencies.teamIDOfApp = { _ in "BBB" }
            dependencies.bundleIdentifierOfApp = { _ in "ch.protonmail.desktop" }
            dependencies.confirmPublisherChange = { _ in confirms }
        }.store
        store.dependencies.teamIDLedger.record(bundleID: TeamIDLedger.caskKey("proton-mail"), teamID: "AAA")
        let item = cask("proton-mail")

        await withLanguage(.pl) {
            store.report(run: publisherChanged(item), planned: [item], caskAppPaths: ["proton-mail": Self.appURL])
            _ = drainBanners(store)
            await store.trustNewPublisher(token: "proton-mail", reportedTeamID: "BBB",
                                          appURL: store.runReport?.entries.first?.appPath)

            #expect(store.runReport?.entries.first?.publisherSettled == confirms)
            store.closeRunReport()
            #expect(publisherBanners(store).count == (confirms ? 0 : 1))
        }
    }

    @Test func anAlreadyTrustedPublisherSettlesTheEntry() async {
        let (defaults, teardown) = TestDefaults.isolated("run-report-already-trusted")
        defer { teardown() }
        let store = makeStore(defaults: defaults) { dependencies in
            dependencies.teamIDOfApp = { _ in "AAA" }
            dependencies.bundleIdentifierOfApp = { _ in "ch.protonmail.desktop" }
            dependencies.confirmPublisherChange = { _ in false }
        }.store
        store.dependencies.teamIDLedger.record(bundleID: TeamIDLedger.caskKey("proton-mail"), teamID: "AAA")
        let item = cask("proton-mail")

        await withLanguage(.pl) {
            store.report(run: publisherChanged(item), planned: [item])
            await store.trustNewPublisher(token: "proton-mail", reportedTeamID: "BBB", appURL: Self.appURL)

            #expect(store.runReport?.entries.first?.publisherSettled == true)
            store.closeRunReport()
            #expect(publisherBanners(store).isEmpty)
        }
    }

    /// Another cask stayed outdated, so the check after the run rebuilt `caskIconPaths` for that
    /// one alone and the list no longer knows where the updated cask lives. The banner the
    /// summary returns carries the bundle the run prepared, and its trust reads that bundle.
    @Test func theReturnedBannerTrustsTheBundleTheRunPrepared() async throws {
        let (defaults, teardown) = TestDefaults.isolated("run-report-banner-trust")
        defer { teardown() }
        let prepared = Self.appURL
        let store = makeStore(defaults: defaults) { dependencies in
            dependencies.teamIDOfApp = { $0 == prepared ? "BBB" : nil }
            dependencies.bundleIdentifierOfApp = { _ in "ch.protonmail.desktop" }
            dependencies.confirmPublisherChange = { _ in true }
        }.store
        let ledger = store.dependencies.teamIDLedger
        ledger.record(bundleID: TeamIDLedger.caskKey("proton-mail"), teamID: "AAA")
        store.caskIconPaths = ["figma": URL(fileURLWithPath: "/TestApplications/Figma.app")]
        let item = cask("proton-mail")

        try await withLanguage(.pl) {
            store.report(run: publisherChanged(item), planned: [item], caskAppPaths: ["proton-mail": prepared])
            store.closeRunReport()
            let action = try #require(publisherBanners(store).first?.action)
            await store.trustNewPublisher(for: action)

            #expect(store.banner?.title == "Zaufano nowemu podpisowi")
            #expect(ledger.teamID(forBundleID: TeamIDLedger.caskKey("proton-mail")) == "BBB")
            #expect(ledger.teamID(forBundleID: "ch.protonmail.desktop") == "BBB")
        }
    }

    /// The banners raised outside the summary (an adoption, a rolled-back row) carry no bundle,
    /// so their trust still looks the app up on the list.
    @Test func aBannerWithoutABundleLooksTheAppUpOnTheList() async {
        let (defaults, teardown) = TestDefaults.isolated("run-report-banner-lookup")
        defer { teardown() }
        let listed = Self.appURL
        let store = makeStore(defaults: defaults) { dependencies in
            dependencies.teamIDOfApp = { $0 == listed ? "BBB" : nil }
            dependencies.bundleIdentifierOfApp = { _ in "ch.protonmail.desktop" }
            dependencies.confirmPublisherChange = { _ in true }
        }.store
        let ledger = store.dependencies.teamIDLedger
        ledger.record(bundleID: TeamIDLedger.caskKey("proton-mail"), teamID: "AAA")
        store.manualOutdated = [ManualOutdatedApp(name: "Proton Mail", path: listed, installedVersion: "1.15.1",
                                                  availableVersion: "1.16.0", source: .cask(token: "proton-mail"))]

        await withLanguage(.pl) {
            await store.trustNewPublisher(for: .trustPublisher(token: "proton-mail", teamID: "BBB"))

            #expect(store.banner?.title == "Zaufano nowemu podpisowi")
            #expect(ledger.teamID(forBundleID: TeamIDLedger.caskKey("proton-mail")) == "BBB")
        }
    }

    /// The undo's rescan is not a scan the user started: it leaves the summary open, and the row
    /// it undid says so instead of offering the copy again.
    @Test func anUndoFromTheSummaryMarksItsRowAndLeavesTheSummaryOpen() async throws {
        let token = "summary-undo-\(UUID().uuidString)"
        let root = try makeScanStoreRuntimeTemporaryDirectory("summary-undo")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let bundleID = "example.summary-undo.\(UUID().uuidString)"
        try makeScanStoreRuntimeApp(at: app, bundleIdentifier: bundleID, version: "1.0", payload: "before")
        let operation = try makeScanStoreRuntimeUndoOperation(token: token, appURL: app, copySnapshot: true)
        defer { UpdateOperationStore.shared.removeOperation(id: operation.operationID) }
        defer { UpdatePolicyStore.shared.remove(key: UpdatePlanner.key(name: token, kind: .cask)) }
        try makeScanStoreRuntimeApp(at: app, bundleIdentifier: bundleID, version: "2.0", payload: "after")
        let store = makeScanStoreRuntimeHarness(runner: Self.quietScanRunner()).store
        let item = cask(token)
        // A second, unattempted row keeps the run short of "finished", so no readiness key is written.
        store.report(run: succeeded([item]), planned: [item, formula("unattempted-\(UUID().uuidString)")],
                     caskOperationID: operation.operationID)
        #expect(store.runReport.flatMap { report in
            report.entries.first.flatMap { report.undo(for: $0, in: [operation.undoable]) }
        } == operation.undoable, "sanity: the summary offers this run's copy")

        await store.undoUpdate(operation.undoable)

        let undone = store.runReport?.entries.first
        #expect(store.runReport != nil, "the undo's rescan does not close the summary")
        #expect(undone?.undoneTo == "1.0")
        #expect(undone.flatMap { store.runReport?.undo(for: $0, in: [operation.undoable]) } == nil)
    }

    @Test func theMarksReachOnlyAnOpenReport() {
        let (defaults, teardown) = TestDefaults.isolated("run-report-marks")
        defer { teardown() }
        let store = makeStore(defaults: defaults).store
        let item = cask("alpha")

        store.markRunReportUndone(token: "alpha", restoredVersion: "1.2")
        store.settleRunReportPublisher(token: "alpha")
        store.closeRunReport()
        #expect(store.runReport == nil && store.banner == nil)

        store.report(run: succeeded([item]), planned: [item])
        store.markRunReportUndone(token: "alpha", restoredVersion: "1.2")
        #expect(store.runReport?.entries.first?.undoneTo == "1.2")
    }

    @Test func selectAllAndToggleAllWorkWithARetainedReport() throws {
        let (defaults, teardown) = TestDefaults.isolated("run-report-select-all")
        defer { teardown() }
        let store = makeStore(defaults: defaults).store
        let queued = formula("queued-\(UUID().uuidString)")
        store.brewOutdated = BrewOutdated(formulae: [
            BrewOutdatedItem(name: queued.name, installedVersions: ["1"], currentVersion: "2"),
        ], casks: [])
        store.status = .results
        let done = formula("done-\(UUID().uuidString)")
        store.report(run: succeeded([done]), planned: [done])
        let report = try #require(store.runReport)

        store.selectAllVisible(filter: .all)
        #expect(store.selected == [queued.key])
        #expect(store.runReport == report)

        store.selected.removeAll()
        store.toggleAll(filter: .all)
        #expect(store.selected == [queued.key])
        #expect(store.runReport == report)
    }

    // MARK: - Wiring

    @Test func theDoorsSitWhereTheirResultIsRecorded() throws {
        let undo = executableSource(try source("Sources/MacUpdater/ScanStore+Undo.swift"))
        let pin = try #require(undo.range(of: "UpdatePolicyStore.shared.pin("))
        let mark = try #require(undo.range(of: "markRunReportUndone(token: undoable.token, restoredVersion: restoredVersion)"))
        let log = try #require(undo.range(of: "WegaLog.info(.homebrew, \"\\(undoable.token): cofnięto aktualizację"))
        #expect(pin.upperBound < mark.lowerBound && mark.upperBound < log.lowerBound, "restore → mark undone → pin → mark the report")

        let trust = executableSource(try source("Sources/MacUpdater/ScanStore+PublisherTrust.swift"))
        let ledger = try #require(trust.range(of: "ledger.acceptPublisherChange(keys: keys, teamID: new)"))
        let alreadyTrusted = try #require(trust.range(of: "case .alreadyTrusted:"))
        let unreadable = try #require(trust.range(of: "case .signatureUnreadable:"))
        let settles = ranges(of: "settleRunReportPublisher(token: token)", in: trust)
        #expect(settles.count == 2)
        #expect(settles.first.map { ledger.upperBound < $0.lowerBound && $0.upperBound < alreadyTrusted.lowerBound } == true,
                "`.accept` settles only once the ledger was written, past the confirmation")
        #expect(settles.last.map { alreadyTrusted.upperBound < $0.lowerBound && $0.upperBound < unreadable.lowerBound } == true)

        let updating = executableSource(try source("Sources/MacUpdater/ScanStore+Updating.swift"))
        #expect(!updating.contains("showStickyBanner(BannerData(variant: .danger, title: tr(\"Zmienił się podpis producenta\")"),
                "the publisher banner is raised only when the report closes")
        let acquire = try #require(updating.range(of: "guard dependencies.upgradeMutex.acquire() else {"))
        let closesForRun = try #require(updating.range(of: "closeRunReport()"))
        let starts = try #require(updating.range(of: "updating = true"))
        #expect(acquire.upperBound < closesForRun.lowerBound && closesForRun.upperBound < starts.lowerBound,
                "a run the lock refuses leaves the summary open")

        let scanning = executableSource(try source("Sources/MacUpdater/ScanStore+Scanning.swift"))
        let guarded = try #require(scanning.range(of: "guard scanTask == nil else { return }"))
        let closesForScan = try #require(scanning.range(of: "closeRunReport()"))
        #expect(guarded.upperBound < closesForScan.lowerBound, "a refused scan leaves the summary open")
    }

    /// Final review C7 — closing has one door because only that door raises the sticky banner of
    /// an unsettled publisher change: `setRunReport(nil)` lives in `closeRunReport()` alone, and
    /// the setter has no caller beyond the report, the door and the two marks.
    @Test func theReportHasOneClosingDoor() throws {
        let directory = packageRoot().appendingPathComponent("Sources/MacUpdater")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var calls: [String: Int] = [:]
        var clears = 0
        for file in files {
            let text = executableSource(try String(contentsOf: file, encoding: .utf8))
            let count = ranges(of: "setRunReport(", in: text).count
            if count > 0 { calls[file.lastPathComponent] = count }
            clears += ranges(of: "setRunReport(nil)", in: text).count
        }
        #expect(calls == ["ScanStore.swift": 1, "ScanStore+RunReport.swift": 3, "ScanStore+Updating.swift": 1], "\(calls)")
        #expect(clears == 1, "only one call clears the report")

        let store = executableSource(try source("Sources/MacUpdater/ScanStore.swift"))
        #expect(store.contains("func setRunReport(_ report: UpdateRunReport?) {\n        runReport = report\n    }"))
        let doors = executableSource(try source("Sources/MacUpdater/ScanStore+RunReport.swift"))
        let close = try #require(doors.range(of: "func closeRunReport() {"))
        let next = try #require(doors.range(of: "func ", range: close.upperBound..<doors.endIndex))
        #expect(doors[close.upperBound..<next.lowerBound].contains("setRunReport(nil)"), "the clear sits in the one door")
        let marks = ["func markRunReportUndone(", "func settleRunReportPublisher("].compactMap { doors.range(of: $0) }
        #expect(marks.count == 2)
        for mark in marks {
            #expect(doors[mark.upperBound...].prefix(200).contains("setRunReport(report)"), "a mark rewrites the open report")
        }
        let updating = executableSource(try source("Sources/MacUpdater/ScanStore+Updating.swift"))
        let opens = try #require(updating.range(of: "func report(run: UpdateRunOutcome, planned:"))
        #expect(updating[opens.upperBound...].prefix(900).contains("setRunReport(report)"), "the report opens it")
    }

    /// Final review C1 — the failure log's headline and per-item lines come from the report, so
    /// every row the summary shows as not updated is named; the summary's per-outcome lines stay.
    @Test func theFailureLogIsWrittenFromTheReport() throws {
        let updating = executableSource(try source("Sources/MacUpdater/ScanStore+Updating.swift"))
        let body = try #require(updating.range(of: "func report(run: UpdateRunOutcome, planned:"))
        let end = try #require(updating.range(of: "func fold(_ result: LaneItemResult", range: body.upperBound..<updating.endIndex))
        let report = updating[body.upperBound..<end.lowerBound]
        #expect(report.contains("WegaLog.error(\n            .homebrew,\n            report.failureLogHeadline,"))
        #expect(report.contains("for line in report.failureLogLinesBeyondTheSummary {\n            WegaLog.error(.homebrew, line)\n        }"))
        #expect(report.contains("for outcome in summary.notUpgraded {\n            WegaLog.error(.homebrew, \"\\(outcome.name): \\(outcome.verdict.logDescription)\")"))
        #expect(!report.contains("Brew zgłosił błąd"), "nothing blames Homebrew for a run where nothing failed")
    }

    private func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while let range = text.range(of: needle, range: start..<text.endIndex) {
            found.append(range)
            start = range.upperBound
        }
        return found
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(path), encoding: .utf8)
    }

    private func executableSource(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
