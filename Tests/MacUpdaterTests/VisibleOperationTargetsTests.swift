import Foundation
import Testing
@testable import MacUpdaterCore

/// UX-01 — every item the next mutation will touch must appear in confirmation.
///
/// Target computation is covered by the pure planner/inventory suites. These checks pin
/// the SwiftUI wiring: updates freeze visible targets, and uninstall freezes the reviewed selection across filters,
/// show that same collection in confirmation UI, and pass it into execution.
@Suite("Visible operation targets")
struct VisibleOperationTargetsTests {
    private let updates = [
        OutdatedItem(key: "f:wget", name: "wget", from: "1", to: "2", kind: .formula),
        OutdatedItem(key: "c:firefox", name: "Firefox", from: "1", to: "2", kind: .cask),
        OutdatedItem(key: "a:1", name: "Xcode", from: "1", to: "2", kind: .appStore),
        OutdatedItem(key: "n:codex", name: "Codex", from: "1", to: "2", kind: .npm),
    ]

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func updateFreezesTheVisibleTargetsBeforeConfirmationAndExecution() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")

        #expect(!view.contains("scan.runUpdate()"),
                "UX-01: an unscoped update treats an empty selection as every item, including rows hidden by the active filter")
        #expect(view.contains("pendingUpdateTargets"),
                "UX-01: confirmation must retain the exact visible update targets the user is approving")
        #expect(view.contains("scan.runUpdate(targetKeys:"),
                "UX-01: execution must receive the same frozen keys shown by confirmation")
    }

    @Test func uninstallUsesOneFrozenCollectionForCountConfirmationAndExecution() throws {
        let view = try source("Sources/MacUpdater/UninstallView.swift")

        #expect(!view.contains("\"\\(selected.count)\""),
                "UX-01: the counter must count only selected installations that still exist and are eligible")
        #expect(view.contains("\"\\(targets.count)\""))
        #expect(view.contains("pendingUninstallTargets = targets"),
                "UX-01: opening confirmation must freeze all eligible installations in the selection")
        #expect(view.range(of: #"UninstallDialog\(\s*targets:\s*pendingUninstallTargets\b"#, options: .regularExpression) != nil,
                "UX-01: confirmation must show the frozen targets")
        #expect(view.contains("let targets = pendingUninstallTargets"))
        #expect(view.range(of: #"await quitThenUninstall\(\s*targets:\s*targets\b"#, options: .regularExpression) != nil)
        #expect(view.contains("operations.runQuitPhase(targets: targets,"))
        #expect(view.range(of: #"await uninstall\(\s*targets:\s*plan\.remove\b"#, options: .regularExpression) != nil,
                "UX-01: execution must remove only the frozen targets cleared by the quit phase")
    }

    @Test func appStoreExecutionCannotExpandOneVisibleTargetIntoGlobalMasUpgrade() throws {
        let actions = try ScanStoreSources.everything()
        let service = try source("Sources/MacUpdaterCore/MasService.swift")

        #expect(!actions.contains("model.masService.upgrade()"),
                "UX-01: bare mas upgrade mutates every outdated App Store row, including hidden or unselected ones")
        #expect(actions.contains("model.masService.upgrade(appStoreIDs:"),
                "UX-01: execution must pass the frozen App Store IDs into mas")
        #expect(service.contains("func upgrade(appStoreIDs:"),
                "UX-01: MasService needs a scoped upgrade entry point")
    }

    @Test func updateTargetsAreTheVisibleSelectedRows() {
        let targets = UpdatePlanner.targets(
            from: updates,
            selectedKeys: ["f:wget", "c:firefox"],
            filter: .apps
        )

        #expect(targets.map(\.key) == ["c:firefox"])
    }

    /// An empty *visible* selection used to mean "every visible row", so switching to a
    /// category where nothing was ticked armed the button with that whole category. A
    /// selection the active filter hides is no selection at all, and no selection is no
    /// batch — the button above this is disabled rather than silently retargeted.
    @Test func noVisibleSelectionMeansNoTargets() {
        let targets = UpdatePlanner.targets(
            from: updates,
            selectedKeys: ["f:wget"],
            filter: .apps
        )

        #expect(targets.isEmpty)
    }

    @Test func anEmptySelectionNeverPlansAnUpgrade() {
        #expect(UpdatePlanner.targets(from: updates, selectedKeys: [], filter: .all).isEmpty)
        #expect(UpdatePlanner.commands(for: UpdatePlanner.plan(selectedKeys: [])).isEmpty)
    }

    @Test func appStoreCommandNamesOnlyTheApprovedID() {
        let plan = UpdatePlanner.plan(selectedKeys: ["a:1"])

        #expect(plan.masAppStoreIDs == ["1"])
        #expect(UpdatePlanner.commands(for: plan) == [
            UpdateCommand(executable: "mas", arguments: ["upgrade", "1"]),
        ])
    }

    @Test func masServicePassesOnlyApprovedIDsToTheProcess() async throws {
        let runner = TargetRecordingProcessRunner()
        let service = MasService(
            locator: BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
            runner: runner
        )

        _ = try await service.upgrade(appStoreIDs: ["1", "2"])

        #expect(runner.requests.map(\.arguments) == [["upgrade", "1", "2"]])
    }

    @Test func uninstallTargetsExcludeAnIDMissingFromInventory() {
        let visible = [app("/Applications/Slack.app", name: "Slack")]
        let hidden = app("/Applications/Firefox.app", name: "Firefox")
        let targets = InstallationInventory.selected(
            visible,
            identities: [visible[0].id, hidden.id]
        )

        #expect(targets.map(\.id) == visible.map(\.id))
    }

    private func app(_ path: String, name: String) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: path),
            name: name,
            bundleIdentifier: "test.\(name)",
            version: "1",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
    }
}

private final class TargetRecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    private(set) var requests: [ProcessRequest] = []
    private let lock = NSLock()

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { requests.append(request) }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func events(for _: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
