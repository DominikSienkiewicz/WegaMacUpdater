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

/// Values only; nothing here exists on disk and nothing reads the real home.
private enum CleanupStoreFixtures {
    static let home = URL(filePath: "/Users/cleanup-test", directoryHint: .isDirectory)

    static let shellPath = CleanupPathSnapshot(
        entries: ["/Users/cleanup-test/.local/bin", "/opt/homebrew/bin", "/usr/bin"], ignoredEntries: [],
        shell: "zsh", capturedAt: Date(timeIntervalSince1970: 1_800_000_000), isApproximate: false
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

    static func intent() -> CleanupRemovalIntent {
        CleanupRemovalIntent(finding: finding(), inUseAcknowledged: false)
    }
}

/// The store's whole system boundary, faked: persisted state, the shell read, the scan and the
/// remover. A gate, when set, holds the scan or the removal until the test opens it.
@MainActor
private final class FakeCleanupBoundary {
    let coordinator = OperationCoordinator()
    var persistedReport: CleanupReport?
    var persistedPath: CleanupPathSnapshot?
    var pathReadResult: CleanupPathReadResult = .failed
    var scanResult = CleanupStoreFixtures.report(tool: "scanned")
    var removalOutcome: CleanupRemovalOutcome = .removed
    /// Thrown by the fake scan after its gate, as the coordinator's lease errors would be.
    var scanError: Error?
    var scanGate: FakeGate?
    var removalGate: FakeGate?

    private(set) var pathReads = 0
    private(set) var scannedPaths: [CleanupPathSnapshot] = []
    private(set) var removedIntents: [CleanupRemovalIntent] = []
    /// Whether each removal's task had been cancelled by the time the fake remover finished.
    private(set) var removalSawCancellation: [Bool] = []
    private(set) var savedReports: [CleanupReport] = []
    private(set) var savedPaths: [CleanupPathSnapshot] = []

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
            savePath: { self.savedPaths.append($0) }
        )
    }

    private func readPath() -> CleanupPathReadResult {
        pathReads += 1
        return pathReadResult
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
