import Foundation
import MacUpdaterCore

@testable import WegaMacUpdater

final class ScanStoreRuntimeProcessRunner: ProcessRunning, @unchecked Sendable {
    typealias RunHandler = @Sendable (ProcessRequest) async throws -> ProcessResult
    typealias EventsHandler = @Sendable (ProcessRequest) -> Result<[ProcessOutputEvent], Error>

    private let lock = NSLock()
    private var recordedRequests: [ProcessRequest] = []
    private let runHandler: RunHandler
    private let eventsHandler: EventsHandler

    init(
        run: @escaping RunHandler,
        events: @escaping EventsHandler = { _ in
            .success([.finished(ProcessResult(exitCode: 0, stdout: "", stderr: ""))])
        }
    ) {
        runHandler = run
        eventsHandler = events
    }

    var requests: [ProcessRequest] {
        lock.withLock { recordedRequests }
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { recordedRequests.append(request) }
        return try await runHandler(request)
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        lock.withLock { recordedRequests.append(request) }
        return AsyncThrowingStream { continuation in
            switch eventsHandler(request) {
            case .success(let events):
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

final class ScanStoreRuntimeSnapshotIO: ScanSnapshotIO, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?

    init(data: Data? = nil) {
        storedData = data
    }

    var data: Data? {
        lock.withLock { storedData }
    }

    func read() throws -> Data? {
        data
    }

    func write(_ data: Data) throws {
        lock.withLock { storedData = data }
    }
}

struct ScanStoreRuntimeApplicationInspector: RunningApplicationInspecting {
    let applications: [RunningApplicationTarget]

    init(applications: [RunningApplicationTarget] = []) {
        self.applications = applications
    }

    @MainActor
    func runningApplications() -> [RunningApplicationTarget] {
        applications
    }
}

@MainActor
final class ScanStoreRuntimeReportRecorder {
    struct Report: Equatable {
        let count: Int
        let failedChecks: Int
        let fingerprint: String
    }

    private(set) var reports: [Report] = []

    func record(count: Int, failedChecks: Int, fingerprint: String) {
        reports.append(Report(count: count, failedChecks: failedChecks, fingerprint: fingerprint))
    }
}

struct ScanStoreRuntimeHarness {
    let store: ScanStore
    let snapshots: ScanStoreRuntimeSnapshotIO
    let reports: ScanStoreRuntimeReportRecorder
}

@MainActor
func makeScanStoreRuntimeHarness(
    runner: ScanStoreRuntimeProcessRunner,
    manualScan: @escaping ScanStoreDependencies.ManualScan = { _, _ in ([], 0) },
    applications: [RunningApplicationTarget] = [],
    undoableUpdates: @escaping () -> [UndoableUpdate] = { [] }
) -> ScanStoreRuntimeHarness {
    let toolURL = URL(fileURLWithPath: "/bin/echo")
    let locator = BinaryLocator(brewCandidates: [toolURL], masCandidates: [toolURL])
    let operations = OperationCoordinator()
    let snapshots = ScanStoreRuntimeSnapshotIO()
    let reports = ScanStoreRuntimeReportRecorder()
    let dependencies = ScanStoreDependencies(
        operations: operations,
        upgrades: UpgradeCoordinator(operations: operations),
        caskAppPathResolver: CaskAppPathResolver(
            applicationsDirectory: URL(fileURLWithPath: "/TestApplications"),
            userApplicationsDirectory: URL(fileURLWithPath: "/TestUserApplications"),
            fileExists: { _ in true }
        ),
        manualScan: manualScan,
        reportWindowScan: { count, failedChecks, fingerprint in
            reports.record(count: count, failedChecks: failedChecks, fingerprint: fingerprint)
        },
        recordUpdateRun: { _ in },
        settleAppManagementPermission: { _ in },
        undoableUpdates: undoableUpdates
    )
    let store = ScanStore(
        resultStore: ScanResultStore(io: snapshots),
        runningApplicationInspector: ScanStoreRuntimeApplicationInspector(applications: applications),
        dependencies: dependencies
    )
    store.attach(model: AppViewModel(
        brewService: BrewService(locator: locator, runner: runner),
        masService: MasService(locator: locator, runner: runner),
        npmService: NpmGlobalService(
            locator: NpmLocator(extraCandidates: [toolURL], runner: runner),
            runner: runner
        )
    ))
    return ScanStoreRuntimeHarness(store: store, snapshots: snapshots, reports: reports)
}
