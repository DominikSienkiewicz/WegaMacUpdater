import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class CleanupStoreTests: XCTestCase {
    func testLaunchLoadsThePersistedReport() {
        let boundary = FakeCleanupBoundary()
        let persisted = CleanupStoreFixtures.report(tool: "persisted")
        boundary.persistedReport = persisted
        boundary.persistedPath = CleanupStoreFixtures.shellPath

        let store = CleanupStore(dependencies: boundary.dependencies)

        XCTAssertEqual(store.report, persisted)
        XCTAssertEqual(store.pathSnapshot, CleanupStoreFixtures.shellPath)
        XCTAssertEqual(store.phase, .idle)
    }

    func testScanWithoutSnapshotUsesTheApproximatePath() async {
        let boundary = FakeCleanupBoundary()
        let scanned = CleanupStoreFixtures.report(tool: "scanned")
        boundary.scanResult = scanned
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await store.task?.value

        XCTAssertEqual(boundary.scannedPaths.map(\.isApproximate), [true])
        XCTAssertEqual(boundary.scannedPaths, [CleanupStoreFixtures.approximatePath])
        XCTAssertNil(store.pathSnapshot, "the approximation is used for the scan, not stored as a shell read")
        XCTAssertEqual(store.report, scanned)
        XCTAssertEqual(boundary.savedReports, [scanned])
        XCTAssertEqual(store.phase, .idle)
    }

    func testScanPrefersTheStoredSnapshot() async {
        let boundary = FakeCleanupBoundary()
        boundary.persistedPath = CleanupStoreFixtures.shellPath
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await store.task?.value

        XCTAssertEqual(boundary.scannedPaths, [CleanupStoreFixtures.shellPath])
    }

    func testReadPathPersistsTheCapturedSnapshot() async {
        let boundary = FakeCleanupBoundary()
        let captured = CleanupStoreFixtures.shellPath
        boundary.pathReadResult = .captured(captured)
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.readPath()
        XCTAssertEqual(store.phase, .readingPath)
        await store.task?.value

        XCTAssertEqual(boundary.pathReads, 1)
        XCTAssertEqual(store.pathReadResult, .captured(captured))
        XCTAssertEqual(store.pathSnapshot, captured)
        XCTAssertEqual(boundary.savedPaths, [captured])
        XCTAssertEqual(store.phase, .idle)
    }

    func testFailedReadKeepsThePreviousSnapshot() async {
        let previous = CleanupStoreFixtures.shellPath
        for result in [CleanupPathReadResult.failed, .unsupportedShell("fish")] {
            let boundary = FakeCleanupBoundary()
            boundary.persistedPath = previous
            boundary.pathReadResult = result
            let store = CleanupStore(dependencies: boundary.dependencies)

            store.readPath()
            await store.task?.value

            XCTAssertEqual(boundary.pathReads, 1, "\(result)")
            XCTAssertEqual(store.pathReadResult, result)
            XCTAssertEqual(store.pathSnapshot, previous, "\(result)")
            XCTAssertTrue(boundary.savedPaths.isEmpty, "\(result)")
            XCTAssertEqual(store.phase, .idle, "\(result)")
        }
    }

    func testCancelStopsTheScanAndKeepsThePreviousReport() async {
        let boundary = FakeCleanupBoundary()
        let previous = CleanupStoreFixtures.report(tool: "previous")
        boundary.persistedReport = previous
        let gate = FakeGate()
        boundary.scanGate = gate
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await fulfillment(of: [gate.entered], timeout: 5)
        store.cancel()
        // Opened as well, so a scan that ignored the cancellation would finish and fail below
        // instead of hanging the run.
        gate.open()
        await store.task?.value

        XCTAssertEqual(boundary.scannedPaths.count, 1)
        XCTAssertEqual(store.report, previous)
        XCTAssertTrue(boundary.savedReports.isEmpty)
        XCTAssertFalse(store.lastScanFailed, "a cancellation is not a failure")
        XCTAssertEqual(store.phase, .idle)
    }

    func testCancelledScanIsNotAnnouncedAsDone() async {
        let boundary = FakeCleanupBoundary()
        let previous = CleanupStoreFixtures.report(tool: "previous")
        boundary.persistedReport = previous
        let gate = FakeGate()
        boundary.scanGate = gate
        let store = CleanupStore(dependencies: boundary.dependencies)
        let stopped = tr("Skan przerwany — poprzedni raport zostaje.")
        let done = tr("Gotowe. Zobacz, co mogę posprzątać.")

        store.scan()
        await fulfillment(of: [gate.entered], timeout: 5)
        store.cancel()
        gate.open()
        await store.task?.value

        XCTAssertTrue(store.lastScanCancelled)
        XCTAssertFalse(store.lastScanFailed, "a cancellation is not a failure")
        XCTAssertEqual(store.report, previous)
        let announced = CleanupPresentation.scanEndedState(failed: store.lastScanFailed, cancelled: store.lastScanCancelled)
        XCTAssertEqual(announced.line, stopped)
        XCTAssertNotEqual(announced.pose, .happy)
        XCTAssertEqual(Translations.en["Skan przerwany — poprzedni raport zostaje."], "Scan stopped — the previous report stays.")

        let next = FakeGate()
        boundary.scanGate = next
        store.scan()
        await fulfillment(of: [next.entered], timeout: 5)
        let cancelledWhileRunning = store.lastScanCancelled
        next.open()
        await store.task?.value

        XCTAssertFalse(cancelledWhileRunning, "a new scan clears the stop when it starts")
        XCTAssertFalse(store.lastScanCancelled)
        XCTAssertEqual(store.report, boundary.scanResult)
        XCTAssertEqual(
            CleanupPresentation.scanEndedState(failed: store.lastScanFailed, cancelled: store.lastScanCancelled).line, done
        )
    }

    func testFailedScanIsPublishedAndClearedByTheNextSuccess() async {
        let boundary = FakeCleanupBoundary()
        let previous = CleanupStoreFixtures.report(tool: "previous")
        boundary.persistedReport = previous
        boundary.scanError = FakeScanFailure()
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await store.task?.value

        XCTAssertTrue(store.lastScanFailed)
        XCTAssertEqual(store.report, previous)
        XCTAssertTrue(boundary.savedReports.isEmpty)

        boundary.scanError = nil
        let gate = FakeGate()
        boundary.scanGate = gate
        store.scan()
        await fulfillment(of: [gate.entered], timeout: 5)
        let failedWhileRunning = store.lastScanFailed
        gate.open()
        await store.task?.value

        XCTAssertFalse(failedWhileRunning, "a new scan clears the previous failure when it starts")
        XCTAssertFalse(store.lastScanFailed)
        XCTAssertEqual(store.report, boundary.scanResult)
    }

    func testSuccessfulRemovalRescans() async {
        let boundary = FakeCleanupBoundary()
        boundary.persistedReport = CleanupStoreFixtures.report(tool: "before")
        boundary.removalOutcome = .removed
        let rescanned = CleanupStoreFixtures.report(tool: "after")
        boundary.scanResult = rescanned
        let store = CleanupStore(dependencies: boundary.dependencies)
        let intent = CleanupStoreFixtures.intent()

        store.remove(intent)
        XCTAssertEqual(store.phase, .removing(findingID: intent.finding.id))
        await store.task?.value

        XCTAssertEqual(boundary.removedIntents, [intent])
        XCTAssertEqual(store.lastOutcome, .removed)
        XCTAssertEqual(boundary.scannedPaths.count, 1)
        XCTAssertEqual(store.report, rescanned)
        XCTAssertEqual(boundary.savedReports, [rescanned])
        XCTAssertEqual(store.phase, .idle)
    }

    func testASuccessfulRemovalMarksTheInventoryStaleAndARefusedOneDoesNot() async {
        let inventory = InventoryStore(operations: OperationCoordinator())
        let boundary = FakeCleanupBoundary()
        boundary.persistedReport = CleanupStoreFixtures.report(tool: "before")
        let store = CleanupStore(dependencies: boundary.dependencies)
        let wiring = store.$removalCount.dropFirst().sink { _ in inventory.markStale() }
        defer { wiring.cancel() }

        boundary.removalOutcome = .needsInUseAcknowledgement([CleanupStoreFixtures.processWithArguments])
        store.remove(CleanupStoreFixtures.intent())
        await store.task?.value
        XCTAssertEqual(store.removalCount, 0)
        XCTAssertFalse(inventory.isStale, "a refused removal changed nothing")

        boundary.removalOutcome = .removed
        store.remove(CleanupStoreFixtures.intent())
        await store.task?.value
        XCTAssertEqual(store.removalCount, 1)
        XCTAssertTrue(inventory.isStale, "the removal went removing -> scanning -> idle, never straight to idle")
    }

    func testNeedsAcknowledgementDoesNotRescan() async {
        let boundary = FakeCleanupBoundary()
        let previous = CleanupStoreFixtures.report(tool: "previous")
        boundary.persistedReport = previous
        let processes = [CleanupStoreFixtures.processWithArguments]
        boundary.removalOutcome = .needsInUseAcknowledgement(processes)
        let store = CleanupStore(dependencies: boundary.dependencies)
        let intent = CleanupStoreFixtures.intent()

        store.remove(intent)
        await store.task?.value

        XCTAssertEqual(boundary.removedIntents, [intent])
        XCTAssertEqual(store.lastOutcome, .needsInUseAcknowledgement(processes))
        XCTAssertTrue(boundary.scannedPaths.isEmpty)
        XCTAssertEqual(store.report, previous)
        XCTAssertEqual(store.phase, .idle)
    }

    func testCancelLeavesARemovalRunning() async {
        let boundary = FakeCleanupBoundary()
        let gate = FakeGate()
        boundary.removalGate = gate
        boundary.persistedReport = CleanupStoreFixtures.report(tool: "claude")
        let store = CleanupStore(dependencies: boundary.dependencies)
        let intent = CleanupStoreFixtures.intent()

        store.remove(intent)
        await fulfillment(of: [gate.entered], timeout: 5)
        store.cancel()
        gate.open()
        await store.task?.value

        XCTAssertEqual(boundary.removalSawCancellation, [false])
        XCTAssertEqual(store.lastOutcome, .removed)
    }

    func testScanRunsUnderAReadLease() async {
        let boundary = FakeCleanupBoundary()
        let gate = FakeGate()
        boundary.scanGate = gate
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await fulfillment(of: [gate.entered], timeout: 5)
        let during = await boundary.coordinator.snapshot()
        let phaseDuring = store.phase
        gate.open()
        await store.task?.value
        let after = await boundary.coordinator.snapshot()

        XCTAssertEqual(during.activeReads, 1)
        XCTAssertNil(during.activeWrite)
        XCTAssertEqual(phaseDuring, .scanning)
        XCTAssertEqual(after.activeReads, 0)
    }

    func testRemovalLogLineNamesTheActionAndTheTildePathOnly() {
        let inUse = CleanupStoreFixtures.finding(status: .inUse([CleanupStoreFixtures.processWithArguments]))
        let caskURL = URL(filePath: "/opt/homebrew/bin/claude", directoryHint: .notDirectory)
        let cask = CleanupFinding(
            detector: .pathDuplicates, tool: "claude", path: caskURL, realpath: caskURL,
            source: .homebrewCask(token: "claude-code"), version: "2.1.311", size: 300_000_000,
            status: .shadowed, reason: .shadowedBy(path: "/Users/cleanup-test/.local/bin/claude"),
            action: .brew(.uninstallCask("claude-code")), risk: .medium, bucket: .safe,
            identity: CleanupFileIdentity(device: 1, inode: 7)
        )

        XCTAssertEqual(
            CleanupStore.removalLogLine(for: inUse, home: CleanupStoreFixtures.home),
            "Porządki: usunięto ~/.local/share/claude/versions/2.1.322 (trash)"
        )
        XCTAssertEqual(
            CleanupStore.removalLogLine(for: cask, home: CleanupStoreFixtures.home),
            "Porządki: usunięto /opt/homebrew/bin/claude (brew uninstall --cask)"
        )
    }

    func testRemovalLogLineNamesBrewCleanup() {
        let kegs = URL(filePath: "/opt/homebrew/Cellar/node", directoryHint: .isDirectory)
        let leftovers = CleanupFinding(
            detector: .homebrew, tool: "node", path: kegs, realpath: kegs,
            source: .homebrewFormula(name: "node"), version: nil, size: 120_000_000,
            status: .unused, reason: .homebrewLeftovers(items: 2), action: .brew(.cleanup("node")),
            risk: .low, bucket: .needsDecision, identity: CleanupFileIdentity(device: 1, inode: 9)
        )

        XCTAssertEqual(
            CleanupStore.removalLogLine(for: leftovers, home: CleanupStoreFixtures.home),
            "Porządki: usunięto /opt/homebrew/Cellar/node (brew cleanup)"
        )
    }

    func testCancelStopsAPathReadAndKeepsTheStoredPath() async {
        let boundary = FakeCleanupBoundary()
        let stored = CleanupStoreFixtures.shellPath
        boundary.persistedPath = stored
        boundary.pathReadResult = .captured(CleanupStoreFixtures.otherShellPath)
        let gate = FakeGate()
        boundary.readGate = gate
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.readPath()
        await fulfillment(of: [gate.entered], timeout: 5)
        store.cancel()
        // Opened as well, so a read that ignored the cancellation would capture the other PATH and
        // fail below instead of hanging the run.
        gate.open()
        await store.task?.value

        XCTAssertEqual(boundary.pathReads, 1)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(store.pathSnapshot, stored)
        XCTAssertNil(store.pathReadResult, "a stopped read is not an error to show")
        XCTAssertTrue(boundary.savedPaths.isEmpty)
    }

    func testSwitchedOffMapIsForgottenAtLaunch() {
        let boundary = FakeCleanupBoundary()
        let mapped = CleanupStoreFixtures.mappedReport()
        boundary.persistedReport = mapped

        let store = CleanupStore(dependencies: boundary.dependencies)

        let kept = CleanupStoreFixtures.reportWithoutMap()
        XCTAssertEqual(store.report, kept)
        XCTAssertEqual(store.report?.findings.map(\.detector), [.pathDuplicates])
        XCTAssertFalse(store.report?.notes.contains { $0.detector == .tccMap } ?? true)
        XCTAssertEqual(store.report?.createdAt, mapped.createdAt)
        XCTAssertEqual(boundary.savedReports, [kept], "the saved report, which the exports read, loses the map too")
    }

    func testMapStaysWhileTheSwitchIsOn() {
        let boundary = FakeCleanupBoundary()
        boundary.tccMapEnabled = true
        let mapped = CleanupStoreFixtures.mappedReport()
        boundary.persistedReport = mapped

        let store = CleanupStore(dependencies: boundary.dependencies)
        store.applyTCCMapSetting()

        XCTAssertEqual(store.report, mapped)
        XCTAssertTrue(boundary.savedReports.isEmpty)
    }

    func testReportWithoutMapIsLeftAlone() {
        let boundary = FakeCleanupBoundary()
        let persisted = CleanupStoreFixtures.reportWithoutMap()
        boundary.persistedReport = persisted

        let store = CleanupStore(dependencies: boundary.dependencies)
        store.applyTCCMapSetting()

        XCTAssertEqual(store.report, persisted)
        XCTAssertTrue(boundary.savedReports.isEmpty)
    }

    func testSwitchingOffLaterForgetsTheMap() {
        let boundary = FakeCleanupBoundary()
        boundary.tccMapEnabled = true
        let mapped = CleanupStoreFixtures.mappedReport()
        boundary.persistedReport = mapped
        let store = CleanupStore(dependencies: boundary.dependencies)
        let launched = store.report

        boundary.tccMapEnabled = false
        store.applyTCCMapSetting()

        XCTAssertEqual(launched, mapped)
        XCTAssertEqual(store.report, CleanupStoreFixtures.reportWithoutMap())
        XCTAssertEqual(boundary.savedReports, [CleanupStoreFixtures.reportWithoutMap()])
    }

    func testAScanFinishedWithTheSwitchOffKeepsNoMap() async {
        let boundary = FakeCleanupBoundary()
        boundary.tccMapEnabled = true
        boundary.scanResult = CleanupStoreFixtures.mappedReport()
        let gate = FakeGate()
        boundary.scanGate = gate
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await fulfillment(of: [gate.entered], timeout: 5)
        boundary.tccMapEnabled = false
        store.applyTCCMapSetting()
        let savedWhileScanning = boundary.savedReports
        gate.open()
        await store.task?.value

        XCTAssertTrue(savedWhileScanning.isEmpty, "no report was stored, so there is nothing to rewrite under the scan")
        XCTAssertEqual(store.report, CleanupStoreFixtures.reportWithoutMap())
        XCTAssertEqual(
            boundary.savedReports, [CleanupStoreFixtures.reportWithoutMap()], "the scanned map never reaches the saved report"
        )
    }

    func testMapSwitchedOffDuringAStoppedScanIsForgottenWhenItStops() async {
        let boundary = FakeCleanupBoundary()
        boundary.tccMapEnabled = true
        let mapped = CleanupStoreFixtures.mappedReport()
        boundary.persistedReport = mapped
        let gate = FakeGate()
        boundary.scanGate = gate
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await fulfillment(of: [gate.entered], timeout: 5)
        boundary.tccMapEnabled = false
        store.applyTCCMapSetting()
        let reportWhileScanning = store.report
        store.cancel()
        gate.open()
        await store.task?.value

        XCTAssertNotEqual(reportWhileScanning, mapped)
        XCTAssertEqual(reportWhileScanning, CleanupStoreFixtures.reportWithoutMap(), "the map is forgotten under a running scan")
        XCTAssertTrue(store.lastScanCancelled)
        XCTAssertEqual(store.report, CleanupStoreFixtures.reportWithoutMap())
        XCTAssertEqual(boundary.savedReports, [CleanupStoreFixtures.reportWithoutMap()])
    }

    /// All store work runs on the main actor and a finished scan follows the switch anyway, so a
    /// map switched off is forgotten at once, also while a scan runs, and no export can carry it.
    func testSwitchingOffDuringARunningScanStripsTheStoredMapAtOnce() async {
        let boundary = FakeCleanupBoundary()
        boundary.tccMapEnabled = true
        boundary.persistedReport = CleanupStoreFixtures.mappedReport()
        boundary.scanResult = CleanupStoreFixtures.mappedReport()
        let gate = FakeGate()
        boundary.scanGate = gate
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await fulfillment(of: [gate.entered], timeout: 5)
        boundary.tccMapEnabled = false
        store.applyTCCMapSetting()
        let reportWhileScanning = store.report
        let savedWhileScanning = boundary.savedReports
        gate.open()
        await store.task?.value

        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(reportWhileScanning, CleanupStoreFixtures.reportWithoutMap())
        XCTAssertEqual(savedWhileScanning, [CleanupStoreFixtures.reportWithoutMap()], "the saved copy loses the map at once too")
        XCTAssertEqual(store.report, CleanupStoreFixtures.reportWithoutMap(), "the scanned map never reaches the screen")
        XCTAssertEqual(boundary.savedReports, [CleanupStoreFixtures.reportWithoutMap(), CleanupStoreFixtures.reportWithoutMap()])
    }

    func testStoreIsHeldAboveTheLanguageReKey() throws {
        let app = try source("Sources/MacUpdater/MacUpdaterApp.swift", root: packageRoot())
        let ownership = try XCTUnwrap(app.range(of: "@StateObject private var cleanup = CleanupStore()"))
        let injection = try XCTUnwrap(app.range(of: ".environmentObject(cleanup)"))
        let reKey = try XCTUnwrap(app.range(of: ".id(localization.language)", range: injection.upperBound..<app.endIndex))

        XCTAssertLessThan(ownership.lowerBound, injection.lowerBound)
        XCTAssertLessThan(injection.lowerBound, reKey.lowerBound)
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String, root: URL) throws -> String {
        try String(contentsOf: root.appending(path: path, directoryHint: .notDirectory), encoding: .utf8)
    }
}

// MARK: - Keep choice

extension CleanupStoreTests {
    private typealias Keep = CleanupKeepFixtures

    func testLaunchReAppliesTheRememberedChoice() {
        let boundary = FakeCleanupBoundary()
        boundary.persistedReport = Keep.report()
        boundary.keptCopies = Keep.keepLink

        let store = CleanupStore(dependencies: boundary.dependencies)

        XCTAssertEqual(store.report, Keep.report(choices: Keep.keepLink))
    }

    func testKeepRecordsTheChoiceAndReResolvesTheReport() throws {
        let boundary = FakeCleanupBoundary()
        boundary.persistedReport = Keep.report()
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.keep(Keep.appLink.id)

        XCTAssertEqual(boundary.savedKeptCopies, [
            ["ollama": CleanupKeptCopy(path: "/usr/local/bin/ollama", source: .appBundle(name: "Ollama"))],
        ])
        let report = try XCTUnwrap(store.report)
        XCTAssertEqual(Keep.finding(Keep.formula.id, in: report)?.action, .brew(.uninstallFormula("ollama")))
        XCTAssertEqual(Keep.finding(Keep.appLink.id, in: report)?.candidate?.keep, .kept)
        XCTAssertEqual(report, Keep.report(choices: Keep.keepLink))
        XCTAssertEqual(boundary.savedReports.last, store.report)
        XCTAssertEqual(store.phase, .idle)
    }

    func testKeepIgnoresAFindingWithoutACandidate() {
        let boundary = FakeCleanupBoundary()
        let previous = CleanupStoreFixtures.report(tool: "previous")
        boundary.persistedReport = previous
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.keep(CleanupStoreFixtures.finding(tool: "previous").id)
        store.keep("D1:shadowed:/nowhere")

        XCTAssertTrue(boundary.savedKeptCopies.isEmpty)
        XCTAssertTrue(boundary.savedReports.isEmpty)
        XCTAssertEqual(store.report, previous)
    }

    func testScanAppliesTheRememberedChoice() async {
        let boundary = FakeCleanupBoundary()
        boundary.keptCopies = Keep.keepLink
        boundary.scanResult = Keep.report()
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await store.task?.value

        let resolved = Keep.report(choices: Keep.keepLink)
        XCTAssertEqual(store.report, resolved)
        XCTAssertEqual(boundary.savedReports, [resolved])
        XCTAssertEqual(store.report.flatMap { Keep.finding(Keep.formula.id, in: $0) }?.action, .brew(.uninstallFormula("ollama")))
        XCTAssertTrue(boundary.savedKeptCopies.isEmpty, "a choice that still matches is not rewritten")
    }

    func testScanDropsAChoiceThatNoLongerMatches() async {
        let boundary = FakeCleanupBoundary()
        boundary.keptCopies = ["ollama": CleanupKeptCopy(path: Keep.linkPath, source: .homebrewFormula(name: "ollama"))]
        boundary.scanResult = Keep.report()
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await store.task?.value

        XCTAssertEqual(boundary.savedKeptCopies, [[:]])
        XCTAssertEqual(store.report, Keep.report())
        XCTAssertEqual(store.report.flatMap { Keep.finding(Keep.formula.id, in: $0) }?.candidate?.keep, .kept)

        store.keep(Keep.appLink.id)
        XCTAssertEqual(boundary.savedKeptCopies.last, Keep.keepLink, "the dropped choice is gone, the new one alone is saved")
    }

    func testKeepIsIgnoredWhileAnOperationRuns() async {
        let boundary = FakeCleanupBoundary()
        boundary.persistedReport = Keep.report()
        let gate = FakeGate()
        boundary.scanGate = gate
        let store = CleanupStore(dependencies: boundary.dependencies)

        store.scan()
        await fulfillment(of: [gate.entered], timeout: 5)
        store.keep(Keep.appLink.id)
        let reportWhileRunning = store.report
        gate.open()
        await store.task?.value

        XCTAssertTrue(boundary.savedKeptCopies.isEmpty)
        XCTAssertEqual(reportWhileRunning, Keep.report())
        XCTAssertEqual(store.report, boundary.scanResult)
    }

    /// A second window shares the store: a sheet opened for a copy to remove must not remove it
    /// once the user keeps that copy elsewhere, also from the in-use acknowledgement step.
    func testAStaleConfirmationNeverRemovesTheCopyNowKept() async throws {
        let boundary = FakeCleanupBoundary()
        boundary.persistedReport = Keep.report()
        boundary.removalOutcome = .notRemovable
        let store = CleanupStore(dependencies: boundary.dependencies)
        store.keep(Keep.appLink.id)
        let shown = try XCTUnwrap(store.report.flatMap { Keep.finding(Keep.formula.id, in: $0) })
        XCTAssertEqual(shown.action, .brew(.uninstallFormula("ollama")))

        store.keep(Keep.formula.id)
        store.remove(CleanupRemovalIntent(finding: shown, inUseAcknowledged: false))
        await store.task?.value
        store.remove(CleanupRemovalIntent(finding: shown, inUseAcknowledged: true))
        await store.task?.value

        XCTAssertTrue(boundary.removedIntents.isEmpty, "the copy now kept never reaches the remover")
        XCTAssertEqual(store.lastOutcome, .changedSinceScan)
        XCTAssertEqual(store.phase, .idle)

        store.keep(Keep.appLink.id)
        store.remove(CleanupRemovalIntent(finding: shown, inUseAcknowledged: false))
        await store.task?.value
        XCTAssertEqual(boundary.removedIntents.map(\.finding), [shown], "a confirmation that matches the report still goes")
    }
}

/// Values only; nothing here exists on disk and nothing reads the real home.
private enum CleanupStoreFixtures {
    static let home = URL(filePath: "/Users/cleanup-test", directoryHint: .isDirectory)

    static let shellPath = CleanupPathSnapshot(
        entries: ["/Users/cleanup-test/.local/bin", "/opt/homebrew/bin", "/usr/bin"], ignoredEntries: [],
        shell: "zsh", capturedAt: Date(timeIntervalSince1970: 1_800_000_000), isApproximate: false
    )

    /// What a read that ignored its cancellation would bring back.
    static let otherShellPath = CleanupPathSnapshot(
        entries: ["/opt/homebrew/bin", "/usr/bin"], ignoredEntries: [],
        shell: "zsh", capturedAt: Date(timeIntervalSince1970: 1_800_000_600), isApproximate: false
    )

    static let approximatePath = CleanupPathSnapshot(
        entries: ["/usr/bin", "/bin"], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: true
    )

    static let processWithArguments = CleanupProcess(
        pid: 812, name: "claude",
        executablePath: "/Users/cleanup-test/.local/share/claude/versions/2.1.322/claude",
        arguments: ["--chrome-native-host", "--token=secret-value"]
    )

    static func finding(tool: String = "claude", status: CleanupStatus = .unused) -> CleanupFinding {
        let url = URL(filePath: "/Users/cleanup-test/.local/share/claude/versions/2.1.322", directoryHint: .isDirectory)
        return CleanupFinding(
            detector: .versionDirectories, tool: tool, path: url, realpath: url,
            source: .nativeVersionDirectory(tool: tool), version: "2.1.322", size: 307_000_000,
            status: status, reason: .olderVersion(current: "2.1.325"), action: .trash([url]),
            risk: .low, bucket: .safe, identity: CleanupFileIdentity(device: 1, inode: 42)
        )
    }

    static func report(tool: String) -> CleanupReport {
        CleanupReport(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), path: shellPath,
            findings: [finding(tool: tool)], notes: [], skippedProtected: []
        )
    }

    static func duplicateFinding() -> CleanupFinding {
        let url = URL(filePath: "/opt/homebrew/bin/claude", directoryHint: .notDirectory)
        return CleanupFinding(
            detector: .pathDuplicates, tool: "claude", path: url, realpath: url,
            source: .homebrewCask(token: "claude-code"), version: "2.1.311", size: 300_000_000,
            status: .shadowed, reason: .shadowedBy(path: "/Users/cleanup-test/.local/bin/claude"),
            action: .brew(.uninstallCask("claude-code")), risk: .medium, bucket: .safe,
            identity: CleanupFileIdentity(device: 1, inode: 7)
        )
    }

    static func mapFinding() -> CleanupFinding {
        let database = URL(
            filePath: "/Users/cleanup-test/Library/Application Support/com.apple.TCC/TCC.db", directoryHint: .notDirectory
        )
        return CleanupFinding(
            detector: .tccMap, tool: "com.example.editor", path: database, realpath: nil,
            source: .appBundle(name: "com.example.editor"), version: nil, size: nil, status: .info,
            reason: .tccEntry(grants: [CleanupTCCGrant(service: .documents, allowed: true)], link: nil),
            action: .command("tccutil reset SystemPolicyDocumentsFolder com.example.editor"),
            risk: .low, bucket: .excluded, identity: nil
        )
    }

    static let homebrewNote = CleanupDetectorNote(detector: .homebrew, kind: .homebrewUnavailable)
    static let skippedProtected = ["/Users/cleanup-test/Library/Mail"]

    /// A D1 finding and a D10 map entry, a D4 note and a D10 note.
    static func mappedReport() -> CleanupReport {
        CleanupReport(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), path: shellPath,
            findings: [duplicateFinding(), mapFinding()],
            notes: [homebrewNote, CleanupDetectorNote(detector: .tccMap, kind: .tccUnsupportedSchema)],
            skippedProtected: skippedProtected
        )
    }

    /// `mappedReport()` without its D10 finding and D10 note.
    static func reportWithoutMap() -> CleanupReport {
        CleanupReport(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), path: shellPath,
            findings: [duplicateFinding()], notes: [homebrewNote], skippedProtected: skippedProtected
        )
    }

    static func intent() -> CleanupRemovalIntent {
        CleanupRemovalIntent(finding: finding(), inUseAcknowledged: false)
    }
}

/// The store's whole system boundary, faked: persisted state, the shell read, the scan, the
/// remover and the Files and Folders switch. A gate, when set, holds the read, the scan or the
/// removal until the test opens it.
@MainActor
private final class FakeCleanupBoundary {
    let coordinator = OperationCoordinator()
    var persistedReport: CleanupReport?
    var persistedPath: CleanupPathSnapshot?
    var pathReadResult: CleanupPathReadResult = .failed
    var scanResult = CleanupStoreFixtures.report(tool: "scanned")
    var removalOutcome: CleanupRemovalOutcome = .removed
    /// The Settings switch for the Files and Folders map; off, like its default.
    var tccMapEnabled = false
    /// The remembered "keep this copy" choices the store loads at launch.
    var keptCopies: [String: CleanupKeptCopy] = [:]
    /// Thrown by the fake scan after its gate, as the coordinator's lease errors would be.
    var scanError: Error?
    var readGate: FakeGate?
    var scanGate: FakeGate?
    var removalGate: FakeGate?

    private(set) var pathReads = 0
    private(set) var scannedPaths: [CleanupPathSnapshot] = []
    private(set) var removedIntents: [CleanupRemovalIntent] = []
    /// Whether each removal's task had been cancelled by the time the fake remover finished.
    private(set) var removalSawCancellation: [Bool] = []
    private(set) var savedReports: [CleanupReport] = []
    private(set) var savedPaths: [CleanupPathSnapshot] = []
    private(set) var savedKeptCopies: [[String: CleanupKeptCopy]] = []

    var dependencies: CleanupStoreDependencies {
        CleanupStoreDependencies(
            home: CleanupStoreFixtures.home,
            coordinator: coordinator,
            readPath: { await self.readPath() },
            approximatePath: { CleanupStoreFixtures.approximatePath },
            scan: { try await self.scan($0) },
            remove: { await self.remove($0) },
            loadReport: { self.persistedReport },
            saveReport: { self.savedReports.append($0) },
            loadPath: { self.persistedPath },
            savePath: { self.savedPaths.append($0) },
            tccMapEnabled: { self.tccMapEnabled },
            loadKeptCopies: { self.keptCopies },
            saveKeptCopies: { self.savedKeptCopies.append($0) }
        )
    }

    /// Like the real reader, a read whose task was cancelled reports `.cancelled`.
    private func readPath() async -> CleanupPathReadResult {
        pathReads += 1
        await readGate?.pass()
        return Task.isCancelled ? .cancelled : pathReadResult
    }

    private func scan(_ path: CleanupPathSnapshot) async throws -> CleanupReport {
        scannedPaths.append(path)
        await scanGate?.pass()
        try Task.checkCancellation()
        if let scanError { throw scanError }
        return scanResult
    }

    private func remove(_ intent: CleanupRemovalIntent) async -> CleanupRemovalOutcome {
        removedIntents.append(intent)
        await removalGate?.pass()
        removalSawCancellation.append(Task.isCancelled)
        return removalOutcome
    }
}

private struct FakeScanFailure: Error {}

/// Holds a fake operation until `open()` or until its task is cancelled. It suspends and never
/// blocks a thread: a blocked cooperative pool turns this project's CI timing tests red.
@MainActor
private final class FakeGate {
    let entered = XCTestExpectation(description: "the fake operation reached its gate")
    private let release: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (release, releaseContinuation) = AsyncStream.makeStream()
    }

    /// Returns once the gate is opened or the calling task is cancelled.
    func pass() async {
        entered.fulfill()
        for await _ in release {}
    }

    func open() {
        releaseContinuation.finish()
    }
}
