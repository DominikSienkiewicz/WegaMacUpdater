import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Migration store production coverage", .serialized)
@MainActor
struct MigrationStoreCoverageTests {
    private enum TestFailure: Error { case expected }

    @Test func scanPublishesCandidatesDuplicatesPublisherSignalsAndMasMatches() async {
        var dependencies = inertDependencies()
        dependencies.fetchCasks = { [BrewCask(token: "figma", name: ["Figma"])] }
        dependencies.scanDirectories = { [URL(fileURLWithPath: "/Applications")] }
        let figma = app("Figma", token: "figma", provenance: .token)
        let pages = app("Pages", token: nil)
        let managed = app("Managed", token: "managed", provenance: .token, managedByBrew: true)
        dependencies.scanApplicationDirectories = { _, _, _ in [figma, pages, managed] }

        let runner = MigrationCoverageRunner { request in
            switch request.arguments {
            case ["list", "--cask", "-1"]:
                return ProcessResult(exitCode: 0, stdout: "codex\n", stderr: "")
            case ["ls", "-g", "--json", "--depth=0"]:
                return ProcessResult(
                    exitCode: 0,
                    stdout: #"{"dependencies":{"@openai/codex":{"version":"1.0.0"}}}"#,
                    stderr: ""
                )
            case ["search", "Pages"]:
                return ProcessResult(exitCode: 0, stdout: "  409201541  Pages  14.4\n", stderr: "")
            default:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
        let store = MigrationStore(
            publisherCorrelator: CaskPublisherCorrelator(
                expectedTeamIDForCask: { $0 == "figma" ? "TEAM" : nil },
                installedTeamIDForApp: { _ in "TEAM" }
            ),
            dependencies: dependencies
        )
        var wegaStates: [WegaState] = []

        await store.scan(model: model(runner: runner), onWegaState: { wegaStates.append($0) })

        guard case .results = store.status else {
            Issue.record("A completed migration scan must publish the results state")
            return
        }
        #expect(store.candidates == [figma, pages])
        #expect(store.npmBrewDuplicates == [NpmBrewDuplicate(npmPackage: "@openai/codex", brewToken: "codex")])
        #expect(store.masCandidates.count == 1)
        #expect(store.masCandidates.first?.app == pages)
        #expect(store.masCandidates.first?.masID == "409201541")
        #expect(store.publisherCorrelations[figma.id]?.installedAppTeamID == "TEAM")
        #expect(wegaStates.first?.pose == .sniff)
        #expect(wegaStates.last?.pose == .alert)
        #expect(store.errorMessage == nil)
    }

    @Test func scanFailureClearsStaleResultsAndStillSettlesTheStateMachine() async {
        var dependencies = inertDependencies()
        dependencies.fetchCasks = { throw TestFailure.expected }
        let store = MigrationStore(dependencies: dependencies)
        store.candidates = [app("Stale", token: "stale", provenance: .token)]
        store.masCandidates = [(app: app("Mas", token: nil), masID: "1")]

        await store.scan(model: model(), onWegaState: nil)

        guard case .results = store.status else {
            Issue.record("A failed migration scan must still settle in the results state")
            return
        }
        #expect(store.candidates.isEmpty)
        #expect(store.publisherCorrelations.isEmpty)
        #expect(store.errorMessage != nil)
    }

    @Test func aScanAlreadyInProgressIsIgnored() async {
        var dependencies = inertDependencies()
        let fetches = MigrationAsyncCounter()
        dependencies.fetchCasks = {
            await fetches.increment()
            return []
        }
        let store = MigrationStore(dependencies: dependencies)
        store.status = .scanning

        await store.scan(model: model(), onWegaState: nil)

        #expect(await fetches.value == 0)
        guard case .scanning = store.status else {
            Issue.record("An ignored overlapping scan must preserve the scanning state")
            return
        }
    }

    @Test func ambiguousRunningApplicationStopsBeforeAnyMutation() async {
        let candidate = app("Figma", token: "figma", provenance: .token)
        let first = runningTarget(pid: 10, app: candidate)
        let second = runningTarget(pid: 11, app: candidate)
        let store = MigrationStore(
            runningApplicationInspector: MigrationSequenceInspector([[first, second]]),
            publisherCorrelator: unknownPublisherCorrelator(),
            dependencies: inertDependencies()
        )

        await store.migrate(candidate, model: model(), onWegaState: nil)

        #expect(store.migrating == nil)
        #expect(store.errorMessage?.contains(candidate.bundleIdentifier ?? "missing") == true)
        #expect(store.pendingForceTermination == nil)
    }

    @Test func aStillRunningApplicationProducesAnExplicitForceTerminationRequest() async {
        let candidate = app("Figma", token: "figma", provenance: .token)
        let target = runningTarget(pid: 12, app: candidate)
        let terminator = MigrationTerminator(result: false)
        let store = MigrationStore(
            runningApplicationInspector: MigrationSequenceInspector([[target]]),
            runningApplicationTerminator: terminator,
            publisherCorrelator: unknownPublisherCorrelator(),
            dependencies: inertDependencies()
        )

        await store.migrate(candidate, model: model(), onWegaState: nil)

        #expect(store.migrating == nil)
        #expect(store.pendingForceTermination?.target == target)
        #expect(terminator.requested == [target])
        #expect(store.logLines.count == 2)
    }

    @Test func forceTerminationFailureAndAmbiguityAreReportedWithoutMigration() async {
        let candidate = app("Figma", token: "figma", provenance: .token)
        let target = runningTarget(pid: 13, app: candidate)
        let request = PendingForceTermination(app: candidate, target: target)

        let killFailureRunner = MigrationCoverageRunner(
            run: { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "denied") }
        )
        let killFailure = MigrationStore(
            processes: RunningProcessService(runner: killFailureRunner),
            runningApplicationInspector: MigrationSequenceInspector([[target]]),
            dependencies: inertDependencies()
        )
        killFailure.pendingForceTermination = request
        await killFailure.forceTerminateAndMigrate(request, model: model(), onWegaState: nil)
        #expect(killFailure.migrating == nil)
        #expect(killFailure.pendingForceTermination == nil)
        #expect(killFailure.errorMessage != nil)

        let ambiguous = MigrationStore(
            runningApplicationInspector: MigrationSequenceInspector([[
                target,
                runningTarget(pid: 14, app: candidate),
            ]]),
            dependencies: inertDependencies()
        )
        await ambiguous.forceTerminateAndMigrate(request, model: model(), onWegaState: nil)
        #expect(ambiguous.migrating == nil)
        #expect(ambiguous.errorMessage != nil)
    }

    @Test func forceTerminationThatDoesNotStopTheProcessIsReported() async {
        let candidate = app("Figma", token: "figma", provenance: .token)
        let target = runningTarget(pid: 15, app: candidate)
        let request = PendingForceTermination(app: candidate, target: target)
        let runner = MigrationCoverageRunner(
            run: { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") }
        )
        let store = MigrationStore(
            processes: RunningProcessService(runner: runner),
            runningApplicationInspector: MigrationSequenceInspector([[target]]),
            dependencies: inertDependencies()
        )

        await store.forceTerminateAndMigrate(request, model: model(), onWegaState: nil)

        #expect(store.migrating == nil)
        #expect(store.errorMessage?.contains("nadal działa") == true)
    }

    @Test func replacementPreparationFailuresProduceSpecificUserFacingStates() async {
        let candidate = app("Figma", token: "figma", provenance: .token)

        var resourceDependencies = inertDependencies()
        resourceDependencies.prepareReplacement = { _, _, _ in .resourcePostponed("low disk") }
        let resource = MigrationStore(
            publisherCorrelator: unknownPublisherCorrelator(),
            dependencies: resourceDependencies
        )
        await resource.migrate(candidate, model: model(), onWegaState: nil)
        #expect(resource.errorMessage?.contains("low disk") == true)
        #expect(resource.logLines.first?.hasPrefix("⏸") == true)

        var publisherDependencies = inertDependencies()
        publisherDependencies.prepareReplacement = { _, _, _ in
            .publisherRejected(old: "OLD", new: "NEW")
        }
        let publisher = MigrationStore(
            publisherCorrelator: unknownPublisherCorrelator(),
            dependencies: publisherDependencies
        )
        await publisher.migrate(candidate, model: model(), onWegaState: nil)
        #expect(publisher.errorMessage?.contains("OLD") == true)
        #expect(publisher.errorMessage?.contains("NEW") == true)

        var snapshotDependencies = inertDependencies()
        snapshotDependencies.prepareReplacement = { _, _, _ in .snapshotFailed }
        let snapshot = MigrationStore(
            publisherCorrelator: unknownPublisherCorrelator(),
            dependencies: snapshotDependencies
        )
        await snapshot.migrate(candidate, model: model(), onWegaState: nil)
        #expect(snapshot.errorMessage?.contains("snapshotu") == true)
        #expect(resource.migrating == nil)
        #expect(publisher.migrating == nil)
        #expect(snapshot.migrating == nil)
    }

    @Test func healthyMigrationRecordsSuccessAndClearsTransientLogs() async throws {
        let candidate = app("Figma", token: "figma", provenance: .token)
        let fixture = try preparation(for: candidate)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var dependencies = inertDependencies()
        dependencies.prepareReplacement = { _, _, _ in .ready(fixture.value) }
        dependencies.resolveInstalledAppURL = { _, _ in candidate.path }
        dependencies.verifyReplacement = { _, _ in .healthy }
        let runner = MigrationCoverageRunner(eventExitCode: 0, eventOutput: "installing\n")
        let store = MigrationStore(
            publisherCorrelator: unknownPublisherCorrelator(),
            dependencies: dependencies
        )
        var states: [WegaState] = []

        await store.migrate(candidate, model: model(runner: runner), onWegaState: { states.append($0) })

        #expect(store.migrated == ["figma"])
        #expect(store.banner?.variant == .success)
        #expect(store.logLines.isEmpty)
        #expect(store.errorMessage == nil)
        #expect(store.migrating == nil)
        #expect(states.last?.pose == .happy)
    }

    @Test func installExitAndStreamFailuresRemainVisibleAfterHealthyVerification() async throws {
        let candidate = app("Figma", token: "figma", provenance: .token)

        let nonzeroFixture = try preparation(for: candidate)
        defer { try? FileManager.default.removeItem(at: nonzeroFixture.root) }
        var nonzeroDependencies = inertDependencies()
        nonzeroDependencies.prepareReplacement = { _, _, _ in .ready(nonzeroFixture.value) }
        nonzeroDependencies.resolveInstalledAppURL = { _, _ in candidate.path }
        nonzeroDependencies.verifyReplacement = { _, _ in .healthy }
        let nonzero = MigrationStore(
            publisherCorrelator: unknownPublisherCorrelator(),
            dependencies: nonzeroDependencies
        )
        await nonzero.migrate(
            candidate,
            model: model(runner: MigrationCoverageRunner(eventExitCode: 7)),
            onWegaState: nil
        )
        #expect(nonzero.errorMessage?.contains("kod 7") == true)

        let throwingFixture = try preparation(for: candidate)
        defer { try? FileManager.default.removeItem(at: throwingFixture.root) }
        var throwingDependencies = inertDependencies()
        throwingDependencies.prepareReplacement = { _, _, _ in .ready(throwingFixture.value) }
        throwingDependencies.resolveInstalledAppURL = { _, _ in candidate.path }
        throwingDependencies.verifyReplacement = { _, _ in .healthy }
        let throwing = MigrationStore(
            publisherCorrelator: unknownPublisherCorrelator(),
            dependencies: throwingDependencies
        )
        await throwing.migrate(
            candidate,
            model: model(runner: MigrationCoverageRunner(eventThrows: true)),
            onWegaState: nil
        )
        #expect(throwing.errorMessage != nil)
        #expect(throwing.logLines.contains { $0.hasPrefix("error:") })
    }

    @Test func everyUnhealthyVerificationVerdictStopsTheMigrationHonestly() async throws {
        let candidate = app("Figma", token: "figma", provenance: .token)
        let verdicts: [CaskValidationVerdict] = [
            .rolledBack,
            .rollbackFailed,
            .publisherChanged(old: "OLD", new: "NEW"),
            .publisherChangedAndRolledBack(old: "OLD", new: nil),
        ]

        for verdict in verdicts {
            let fixture = try preparation(for: candidate)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var dependencies = inertDependencies()
            dependencies.prepareReplacement = { _, _, _ in .ready(fixture.value) }
            dependencies.resolveInstalledAppURL = { _, _ in candidate.path }
            dependencies.verifyReplacement = { _, _ in verdict }
            let store = MigrationStore(
                publisherCorrelator: unknownPublisherCorrelator(),
                dependencies: dependencies
            )

            await store.migrate(
                candidate,
                model: model(runner: MigrationCoverageRunner(eventExitCode: 0)),
                onWegaState: nil
            )

            #expect(store.migrated.isEmpty)
            #expect(store.errorMessage != nil)
            #expect(store.logLines.last?.hasPrefix("⚠️") == true)
            #expect(store.migrating == nil)
        }
    }

    @Test func duplicateRemovalCoversBothPackageManagersAndFailureOutcomes() async {
        let duplicate = NpmBrewDuplicate(npmPackage: "@openai/codex", brewToken: "codex")
        for side in [DuplicateRemoval.Side.npm, .brew] {
            let runner = MigrationCoverageRunner(eventExitCode: 0, eventOutput: "removed\n")
            let store = MigrationStore(dependencies: inertDependencies())
            store.npmBrewDuplicates = [duplicate]
            var states: [WegaState] = []

            await store.removeDuplicate(
                DuplicateRemoval(dup: duplicate, side: side),
                model: model(runner: runner),
                onWegaState: { states.append($0) }
            )

            #expect(store.npmBrewDuplicates.isEmpty)
            #expect(store.banner?.variant == .success)
            #expect(store.duplicateBusyKey == nil)
            #expect(states.last?.pose == .happy)
        }

        let failed = MigrationStore(dependencies: inertDependencies())
        failed.npmBrewDuplicates = [duplicate]
        await failed.removeDuplicate(
            DuplicateRemoval(dup: duplicate, side: .brew),
            model: model(runner: MigrationCoverageRunner(eventExitCode: 9, eventOutput: "failed")),
            onWegaState: nil
        )
        #expect(failed.npmBrewDuplicates == [duplicate])
        #expect(failed.banner?.variant == .danger)

        let notStarted = MigrationStore(dependencies: inertDependencies())
        await notStarted.removeDuplicate(
            DuplicateRemoval(dup: duplicate, side: .brew),
            model: model(runner: MigrationCoverageRunner(), locateBrew: false),
            onWegaState: nil
        )
        #expect(notStarted.banner?.variant == .danger)
        #expect(notStarted.duplicateBusyKey == nil)
    }

    @Test func appStoreOpeningUsesTheInjectedWorkspaceBoundary() {
        let opened = MigrationURLBox()
        var dependencies = inertDependencies()
        dependencies.openURL = { opened.value = $0 }
        let store = MigrationStore(dependencies: dependencies)

        store.openAppStore(masID: "409201541")

        #expect(opened.value?.absoluteString == "macappstore://apps.apple.com/app/id409201541")
    }

    private func app(
        _ name: String,
        token: String?,
        provenance: CaskMatchProvenance? = nil,
        managedByBrew: Bool = false
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "example.\(name.lowercased())",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: managedByBrew,
            caskToken: token,
            caskMatchProvenance: provenance
        )
    }

    private func runningTarget(pid: Int32, app: ApplicationInfo) -> RunningApplicationTarget {
        RunningApplicationTarget(
            processIdentifier: pid,
            bundleURL: app.path,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            processName: app.name
        )
    }

    private func unknownPublisherCorrelator() -> CaskPublisherCorrelator {
        CaskPublisherCorrelator(
            expectedTeamIDForCask: { _ in nil },
            installedTeamIDForApp: { _ in nil }
        )
    }

    private func inertDependencies() -> MigrationStore.Dependencies {
        var dependencies = MigrationStore.Dependencies.live
        dependencies.fetchCasks = { [] }
        dependencies.scanDirectories = { [] }
        dependencies.scanApplicationDirectories = { _, _, _ in [] }
        dependencies.waitBetweenRunningChecks = {}
        dependencies.openURL = { _ in }
        return dependencies
    }

    private func model(
        runner: MigrationCoverageRunner = MigrationCoverageRunner(),
        locateBrew: Bool = true
    ) -> AppViewModel {
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        return AppViewModel(
            brewService: BrewService(
                locator: BinaryLocator(brewCandidates: locateBrew ? [executable] : []),
                runner: runner
            ),
            masService: MasService(
                locator: BinaryLocator(masCandidates: [executable]),
                runner: runner
            ),
            npmService: NpmGlobalService(
                locator: NpmLocator(extraCandidates: [executable], runner: runner),
                runner: runner
            )
        )
    }

    private func preparation(
        for app: ApplicationInfo
    ) throws -> (value: CaskReplacementSafety.Preparation, root: URL) {
        let token = try #require(app.caskToken)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-migration-coverage-\(UUID().uuidString)", isDirectory: true)
        let operation = UpdateOperationStore(rootDirectory: root).begin(trigger: .adoption)
        operation.recordPlanned(tokens: [token], appPaths: [token: app.path])
        return (
            CaskReplacementSafety.Preparation(
                token: token,
                snapshotURL: root.appendingPathComponent("snapshot.app"),
                expectedTeamID: nil,
                identity: CaskReplacementArtifactIdentity(
                    bundleIdentifier: app.bundleIdentifier,
                    appURL: app.path
                ),
                operation: operation
            ),
            root
        )
    }
}

private final class MigrationCoverageRunner: ProcessRunning, @unchecked Sendable {
    private let runHandler: @Sendable (ProcessRequest) async throws -> ProcessResult
    private let eventExitCode: Int32
    private let eventOutput: String
    private let eventThrows: Bool

    init(
        eventExitCode: Int32 = 0,
        eventOutput: String = "",
        eventThrows: Bool = false,
        run: @escaping @Sendable (ProcessRequest) async throws -> ProcessResult = { _ in
            ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    ) {
        self.eventExitCode = eventExitCode
        self.eventOutput = eventOutput
        self.eventThrows = eventThrows
        runHandler = run
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try await runHandler(request)
    }

    func events(for _: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { continuation in
            if !eventOutput.isEmpty { continuation.yield(.stdout(eventOutput)) }
            if eventThrows {
                continuation.finish(throwing: MigrationCoverageError.expected)
            } else {
                continuation.yield(.finished(ProcessResult(
                    exitCode: eventExitCode,
                    stdout: eventOutput,
                    stderr: ""
                )))
                continuation.finish()
            }
        }
    }
}

private enum MigrationCoverageError: Error { case expected }

@MainActor
private final class MigrationSequenceInspector: RunningApplicationInspecting, @unchecked Sendable {
    private let snapshots: [[RunningApplicationTarget]]
    private var index = 0

    init(_ snapshots: [[RunningApplicationTarget]]) { self.snapshots = snapshots }

    func runningApplications() -> [RunningApplicationTarget] {
        guard !snapshots.isEmpty else { return [] }
        defer { index += 1 }
        return snapshots[min(index, snapshots.count - 1)]
    }
}

@MainActor
private final class MigrationTerminator: RunningApplicationTargetTerminating, @unchecked Sendable {
    let result: Bool
    private(set) var requested: [RunningApplicationTarget] = []

    init(result: Bool) { self.result = result }

    func requestGracefulTermination(_ target: RunningApplicationTarget) -> Bool {
        requested.append(target)
        return result
    }
}

private actor MigrationAsyncCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class MigrationURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var value: URL? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
