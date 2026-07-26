import Foundation
import Testing
@testable import MacUpdaterCore

/// QA-01a / REL-01 regression — "wybrany jeden element MAS nie aktualizuje pozostałych".
///
/// The guarantee fixed in REL-01: when the Updates list holds several outdated
/// App Store apps and the user selects exactly one, the run upgrades only that
/// app. A bare `mas upgrade` (no IDs) upgrades *every* outdated App Store app,
/// so the single approved ID has to survive the whole chain — selection → plan
/// → command → the actual `mas` invocation — while the unselected apps never
/// reach the process. This suite pins that end to end so the scoped upgrade can
/// never silently collapse back into a global `mas upgrade`.
@Suite("MAS single selection regression (QA-01a / REL-01)")
struct MasSingleSelectionRegressionTests {

    /// Three outdated App Store apps, tagged into selectable rows exactly as a scan
    /// would surface them (`a:<appStoreID>` keys).
    private let outdated = UpdatePlanner.outdatedItems(
        brew: nil,
        mas: [
            MasOutdatedApp(appStoreID: "1", name: "Keynote", installedVersion: "13.0", currentVersion: "14.0"),
            MasOutdatedApp(appStoreID: "2", name: "Numbers", installedVersion: "13.0", currentVersion: "14.0"),
            MasOutdatedApp(appStoreID: "3", name: "Pages", installedVersion: "13.0", currentVersion: "14.0"),
        ],
        npm: []
    )

    @Test func selectingOneAppStoreItemUpgradesOnlyItAndLeavesTheOthersUntouched() async throws {
        // The user ticks a single App Store row (Numbers, id 2) among three outdated ones.
        let plan = UpdatePlanner.plan(selectedKeys: ["a:2"], allKeys: outdated.map(\.key))

        // The plan carries only the approved ID — the other two outdated apps are absent.
        #expect(plan.masAppStoreIDs == ["2"])
        #expect(!plan.masAppStoreIDs.contains("1"))
        #expect(!plan.masAppStoreIDs.contains("3"))

        // The command is a scoped `mas upgrade 2`, never a bare `mas upgrade`
        // (which would upgrade every outdated App Store app).
        let masCommands = UpdatePlanner.commands(for: plan).filter { $0.executable == "mas" }
        #expect(masCommands == [UpdateCommand(executable: "mas", arguments: ["upgrade", "2"])])

        // End to end: the real MasService hands the process exactly the one ID —
        // the two unselected apps never reach `mas`.
        let runner = RecordingProcessRunner()
        let service = MasService(
            locator: BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
            runner: runner
        )

        _ = try await service.upgrade(appStoreIDs: plan.masAppStoreIDs)

        #expect(runner.requests.map(\.arguments) == [["upgrade", "2"]])
        let forwardedArguments = runner.requests.flatMap(\.arguments)
        #expect(!forwardedArguments.contains("1"))
        #expect(!forwardedArguments.contains("3"))
    }
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
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
