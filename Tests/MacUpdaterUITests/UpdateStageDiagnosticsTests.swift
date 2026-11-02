import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

private final class StageActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var actions: [String] { lock.withLock { storage } }
    func append(_ action: String) { lock.withLock { storage.append(action) } }
}

@Suite("Persistent update stage diagnostics")
@MainActor
struct UpdateStageDiagnosticsTests {
    @Test func dockerExemptionRecordsMissingSmokeEvidenceWithoutLaunchingOrRestoring() async throws {
        let fixture = try Fixture(token: "docker-desktop", before: "4.96.0", installed: "4.97.0")
        defer { fixture.cleanUp() }
        let actions = StageActionRecorder()

        let verdict = await fixture.verify(dependencies: dependencies(actions: actions))

        #expect(verdict == .healthy)
        #expect(actions.actions.isEmpty)
        let smoke = fixture.events.first { $0.event == "smoke.result" }
        #expect(smoke?.fields["verdict"] == "skipped")
        #expect(smoke?.fields["reason"] == "privilegedFirstRun")
        #expect(fixture.events.contains { $0.event == "validation.result" && $0.fields["verdict"] == "healthy" })
    }

    @Test func discordNoOpRecordsBothVersionsWithoutStartingSmokeTest() async throws {
        let fixture = try Fixture(token: "discord", before: "0.0.419", installed: "0.0.419")
        defer { fixture.cleanUp() }
        let actions = StageActionRecorder()

        let verdict = await fixture.verify(dependencies: dependencies(actions: actions))

        #expect(verdict == .notUpgraded)
        #expect(actions.actions.isEmpty)
        let arrival = fixture.events.first { $0.event == "validation.arrival" }
        #expect(arrival?.fields["installedVersion"] == "0.0.419")
        #expect(arrival?.fields["snapshotVersion"] == "0.0.419")
        #expect(arrival?.fields["installedNothing"] == "true")
        #expect(fixture.events.contains { $0.event == "validation.result" && $0.fields["verdict"] == "notUpgraded" })
    }

    @Test func discordSelfUpdaterDowngradeRecordsVersionsWithoutAddingARollback() async throws {
        let fixture = try Fixture(token: "discord", before: "0.0.419", installed: "0.0.420")
        defer { fixture.cleanUp() }
        let actions = StageActionRecorder()
        let dependencies = dependencies(actions: actions, launch: { url in
            actions.append("launch")
            _ = try? Self.bundle(at: url, version: "0.0.419")
            return .survived
        })

        let verdict = await fixture.verify(dependencies: dependencies)

        #expect(verdict == .replacedByAppUpdater(version: "0.0.419"))
        #expect(actions.actions == ["launch"])
        let settled = fixture.events.first { $0.event == "selfUpdater.versionObserved" }
        #expect(settled?.fields["arrivedVersion"] == "0.0.420")
        #expect(settled?.fields["settledVersion"] == "0.0.419")
        #expect(fixture.events.allSatisfy { $0.runID == fixture.run.id })
        #expect(!fixture.events.contains { $0.event == "rollback.started" })
    }

    @Test func failedSnapshotRecordsOperationAndBundleOnlyScope() throws {
        let fixture = try Fixture(token: "docker-desktop", before: "4.96.0", installed: "4.97.0")
        defer { fixture.cleanUp() }
        let operationStore = UpdateOperationStore(rootDirectory: fixture.root.appendingPathComponent("operations"))
        let operation = operationStore.begin(trigger: .manual)
        operation.recordPlanned(tokens: [fixture.token], appPaths: [fixture.token: fixture.installed])
        var dependencies = dependencies(actions: StageActionRecorder())
        dependencies.clone = { _, _ in throw CocoaError(.fileWriteNoPermission) }

        let snapshots = UpdateDiagnostics.$current.withValue(fixture.run) {
            CaskRollbackGuard.snapshot(tokens: [fixture.token], appPaths: [fixture.token: fixture.installed],
                                       operation: operation, dependencies: dependencies)
        }

        #expect(snapshots.isEmpty)
        let result = fixture.events.first { $0.event == "snapshot.result" }
        #expect(result?.fields["operationID"] == operation.operation.id.uuidString)
        #expect(result?.fields["scope"] == "appBundleOnly")
        #expect(result?.fields["cloned"] == "false")
        #expect(operation.operation.items.first?.phase == .planned)
    }

    @Test func recoveryLinksTheJournalWithoutInventingACrashOrMutatingAPlannedApp() async throws {
        let fixture = try Fixture(token: "discord", before: "0.0.419", installed: "0.0.420")
        defer { fixture.cleanUp() }
        let actions = StageActionRecorder()
        let operations = UpdateOperationStore(rootDirectory: fixture.root.appendingPathComponent("operations"))
        let session = operations.begin(trigger: .manual)
        session.recordPlanned(tokens: [fixture.token], appPaths: [fixture.token: fixture.installed])
        let recovery = UpdateOperationRecovery(store: operations, dependencies: .init(
            fileExists: { _ in false }, appVersion: { _ in nil },
            verify: { _, _, _, _ in actions.append("verify"); return [:] },
            clone: { _, _ in actions.append("clone") }, recordRollback: { _ in actions.append("rollback") },
            removeItem: { _ in actions.append("remove") }, legacyDirectory: { fixture.root }, announce: { _ in }
        ))

        let report = await UpdateDiagnostics.$current.withValue(fixture.run) {
            await recovery.recoverInterruptedOperations()
        }

        #expect(report.abortedTokens == [fixture.token])
        #expect(actions.actions.isEmpty)
        let action = fixture.events.first { $0.event == "recovery.action" }
        #expect(action?.fields["operationID"] == session.operation.id.uuidString)
        #expect(action?.fields["action"] == "abortWithoutMutation")
        #expect(fixture.events.filter { $0.event == "trace.started" }.count == 1)
        #expect(fixture.events.contains { $0.event == "recovery.summary" && $0.fields["aborted"] == fixture.token })
    }

    @Test func foregroundRecordsPlanRescanAndVerdictWithoutAddingCommands() async throws {
        let fixture = try Fixture(token: "formula", before: "1", installed: "2")
        defer { fixture.cleanUp() }
        let runner = ScanStoreRuntimeProcessRunner(run: { request in
            let output: String
            switch request.arguments {
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                output = #"{"formulae":[],"casks":[]}"#
            case ["outdated"]: output = ""
            case ["outdated", "-g", "--json"]: output = "{}"
            default: throw CocoaError(.executableNotLoadable)
            }
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        })
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(formulae: [
            BrewOutdatedItem(name: "formula", installedVersions: ["1"], currentVersion: "2")
        ], casks: [])

        await UpdateDiagnostics.$current.withValue(fixture.run) {
            await harness.store.runUpdate(targetKeys: ["f:formula"])
        }

        #expect(harness.store.banner?.variant == .success)
        #expect(runner.requests.count == 4)
        #expect(fixture.events.contains { $0.event == "update.plannedItem" && $0.fields["targetVersion"] == "2" })
        #expect(fixture.events.contains { $0.event == "rescan.result" && $0.fields["confirmed"] == "true" })
        #expect(fixture.events.contains { $0.event == "update.itemVerdict" && $0.fields["verdict"] == "succeeded" })
        #expect(fixture.events.filter { $0.event == "trace.started" }.count == 1)
    }

    @Test func discordDetachedSelfUpdaterWorkRetainsContextAndTheSameThreeCommands() async throws {
        let fixture = try Fixture(token: "discord", before: "0.0.419", installed: "0.0.420")
        defer { fixture.cleanUp() }
        let path = fixture.installed.path
        let runner = ScanStoreRuntimeProcessRunner(run: { request in
            UpdateDiagnostics.record("test.processContext", fields: ["command": request.arguments[0]])
            let output: String
            switch request.arguments.first {
            case "list": output = "0\t0\tcom.discord.discord.ShipIt\n"
            case "print": output = "program = \(path)/Contents/Frameworks/Squirrel.framework/ShipIt\n"
            case "remove": output = ""
            default: throw CocoaError(.executableNotLoadable)
            }
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        })

        let withdrawn = await UpdateDiagnostics.$current.withValue(fixture.run) {
            await SquirrelShipItJob.withdraw(fromBundleAt: fixture.installed, runner: runner)
        }

        #expect(withdrawn == ["com.discord.discord.ShipIt"])
        #expect(runner.requests.map { $0.arguments[0] } == ["list", "print", "remove"])
        let observed = fixture.events.filter { $0.event == "test.processContext" }
        #expect(observed.count == 3)
        #expect(observed.allSatisfy { $0.runID == fixture.run.id })
        #expect(fixture.events.contains { $0.event == "selfUpdater.withdrawResult" && $0.fields["withdrawnCount"] == "1" })
    }

    @Test func rejectedGatekeeperKeepsRollbackCorrelatedAfterPathRedaction() async throws {
        let fixture = try Fixture(token: "discord", before: "0.0.419", installed: "0.0.420")
        defer { fixture.cleanUp() }
        let actions = StageActionRecorder()
        var dependencies = dependencies(actions: actions)
        dependencies.passesGatekeeper = { _ in false }

        let verdict = await fixture.verify(dependencies: dependencies)

        #expect(verdict == .rolledBack)
        #expect(actions.actions == ["restore"])
        let rollback = fixture.events.filter { $0.event == "rollback.started" || $0.event == "rollback.result" }
        #expect(rollback.count == 2)
        #expect(rollback.allSatisfy { $0.fields["token"] == "discord" })
        #expect(rollback.last?.fields["restored"] == "true")
    }

    private func dependencies(
        actions: StageActionRecorder,
        launch: (@Sendable (URL) async -> LaunchSmokeTest.Verdict)? = nil
    ) -> CaskRollbackGuard.Dependencies {
        CaskRollbackGuard.Dependencies(
            teamIDBeforeMutation: { _ in "TEAM" },
            teamIDAfterMutation: { _ in "TEAM" },
            recordTeamID: { _, teamID in .unchanged(teamID: teamID) },
            applyRollbackLedger: { _, _ in },
            clone: { _, _ in actions.append("clone") },
            bundleIdentifier: { _ in "com.example.app" },
            passesGatekeeper: { _ in true },
            restore: { _, _ in actions.append("restore") },
            helperIsEnabled: { false },
            helperReplace: { _, _ in actions.append("helperReplace") },
            removeItem: { _ in actions.append("remove") },
            smokeTestIsEnabled: { true },
            launchSmokeTest: launch ?? { _ in actions.append("launch"); return .survived }
        )
    }

    private struct Fixture {
        let root: URL
        let token: String
        let snapshot: URL
        let installed: URL
        let store: DiagnosticTraceStore
        let run: DiagnosticRun

        init(token: String, before: String, installed version: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("stage-diagnostics-\(UUID())")
            self.token = token
            snapshot = try UpdateStageDiagnosticsTests.bundle(at: root.appendingPathComponent("snapshot.app"), version: before)
            installed = try UpdateStageDiagnosticsTests.bundle(at: root.appendingPathComponent("installed.app"), version: version)
            store = DiagnosticTraceStore(directory: root.appendingPathComponent("traces"))
            run = DiagnosticRun(trigger: "test", subjects: [token], store: store)
        }

        var events: [DiagnosticEvent] { store.events(runID: run.id) }

        @MainActor
        func verify(dependencies: CaskRollbackGuard.Dependencies) async -> CaskValidationVerdict {
            await UpdateDiagnostics.$current.withValue(run) {
                await CaskRollbackGuard.verify(token: token, snapshotURL: snapshot, validationURL: installed,
                    expecting: .init(teamID: "TEAM", bundleIdentifier: "com.example.app", version: "target"),
                    dependencies: dependencies)
            }
        }

        func cleanUp() {
            run.finish()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private nonisolated static func bundle(at url: URL, version: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleShortVersionString": version, "CFBundleIdentifier": "com.example.app"
        ], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
