import Combine
import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// C2 stage 3 — what the store knows about each planned row and each batch while a run works,
/// and that it says nothing more than that.
@Suite("Update run board") @MainActor
struct UpdateRunBoardTests {
    @Test func everyStatusSaysOnlyWhatTheRunKnows() {
        withLanguage(.pl) {
            #expect(UpdateRunRowStatus.waiting.title(isStopping: false) == "czeka")
            #expect(UpdateRunRowStatus.waiting.title(isStopping: true) == "nie zacznę")
            #expect(UpdateRunRowStatus.installing.title(isStopping: true) == "instaluję…")
            #expect(UpdateRunRowStatus.installedChecking.title(isStopping: false) == "zainstalowano — sprawdzam")
            #expect(UpdateRunRowStatus.failed.title(isStopping: false) == "nie udało się")
            #expect(UpdateRunRowStatus.notStarted.title(isStopping: false) == "nie zacznę")
            #expect(UpdateRunRowStatus.installing.laneTitle(isStopping: false) == "w toku")
        }
        withLanguage(.en) {
            #expect(UpdateRunRowStatus.waiting.title(isStopping: false) == "waiting")
            #expect(UpdateRunRowStatus.waiting.title(isStopping: true) == "won't start")
            #expect(UpdateRunRowStatus.installing.title(isStopping: false) == "installing…")
            #expect(UpdateRunRowStatus.installedChecking.title(isStopping: false) == "installed — checking")
            #expect(UpdateRunRowStatus.failed.title(isStopping: false) == "failed")
            #expect(UpdateRunRowStatus.installing.laneTitle(isStopping: false) == "in progress")
        }
        let titles = [UpdateRunRowStatus.waiting, .installing, .installedChecking, .failed, .notStarted]
            .map { $0.title(isStopping: false) }
        #expect(!titles.contains { $0.contains("zaktualizowano") }, "REL-02: never 'updated' during a run")
    }

    @Test func onlyCasksAndNpmGetARowStatusAndTheBatchLanesSpeakOnTheirHeader() {
        let board = UpdateRunBoard(startedAt: .now, planned: ["c:a", "n:b", "f:c", "a:1"],
                                   rows: ["c:a": .installing, "n:b": .waiting],
                                   lanes: [.formulae: .installing, .appStore: .waiting])
        let state = UpdateRunListState(board: board, isStopping: false)
        #expect(state.rowStatus(for: OutdatedItem(key: "c:a", name: "a", from: "1", to: "2", kind: .cask)) == .installing)
        #expect(state.rowStatus(for: OutdatedItem(key: "f:c", name: "c", from: "1", to: "2", kind: .formula)) == nil)
        #expect(state.isDimmed("c:other") && !state.isDimmed("f:c"))
        withLanguage(.pl) {
            #expect(state.laneNote(for: [.formula, .npm]) == "Narzędzia Homebrew: w toku")
            #expect(state.laneNote(for: [.cask, .appStore]) == "Mac App Store: czeka")
            #expect(state.laneNote(for: [.cask]) == nil)
            #expect(state.laneNote(for: [.formula, .appStore]) == "Narzędzia Homebrew: w toku · Mac App Store: czeka")
        }
        let stopping = UpdateRunListState(board: board, isStopping: true)
        withLanguage(.pl) { #expect(stopping.laneNote(for: [.appStore]) == "Mac App Store: nie zacznę") }
    }

    /// The formula batch has no stop gate of its own: it starts with the run, so a stop
    /// request must not make it promise „nie zacznę” and then start anyway.
    @Test func onlyABatchThatAsksTheStopSwitchSaysItWillNotStart() {
        #expect(!UpdateRunLane.formulae.stopsBeforeStarting)
        #expect(UpdateRunLane.appStore.stopsBeforeStarting)
        let queued = UpdateRunBoard(startedAt: .now, planned: ["f:c", "a:1"],
                                    lanes: [.formulae: .waiting, .appStore: .waiting])
        let stopping = UpdateRunListState(board: queued, isStopping: true)
        withLanguage(.pl) {
            #expect(stopping.laneNote(for: [.formula]) == "Narzędzia Homebrew: czeka")
            #expect(stopping.laneNote(for: [.appStore]) == "Mac App Store: nie zacznę")
        }
    }

    @Test func aRunWalksEveryRowAndLaneThroughWhatItKnowsAndClearsTheBoard() async {
        let (harness, keys) = Self.harness(npmFails: false)
        let recorder = BoardRecorder()
        let watch = harness.store.$runBoard.sink { recorder.boards.append($0) }
        defer { watch.cancel() }

        await harness.store.runUpdate(targetKeys: keys.all)

        #expect(recorder.rows(keys.npm) == [.waiting, .installing, .installedChecking])
        #expect(recorder.lanes(.formulae) == [.waiting, .installing, .installedChecking])
        #expect(recorder.lanes(.appStore) == [.waiting, .installing, .installedChecking])
        #expect(recorder.boards.contains { $0.startedAt != nil && $0.planned == keys.all })
        #expect(harness.store.runBoard == .idle)
    }

    @Test func aFailedPackageSaysSoAndNeverReadsInstalled() async {
        let (harness, keys) = Self.harness(npmFails: true)
        let recorder = BoardRecorder()
        let watch = harness.store.$runBoard.sink { recorder.boards.append($0) }
        defer { watch.cancel() }
        await harness.store.runUpdate(targetKeys: keys.all)
        #expect(recorder.rows(keys.npm) == [.waiting, .installing, .failed])
    }

    @Test func theLanesMarkEveryBoundaryTheyCross() throws {
        let lanes = compact(try source("Sources/MacUpdater/ScanStore+UpgradeLanes.swift"))
        #expect(lanes.contains("markRunRow(item.key, .installing) beginItem(named: token)"))
        #expect(lanes.contains("markRunRow(item.key, outcome.isSuccessful ? .installedChecking : .failed) let verdicts = await postCaskUpgrade("))
        #expect(lanes.contains("markRunRow(item.key, .installing) beginItem(named: name) defer { endItem() } let outcome = await runNpmUpgrade(name: name) if outcome.isSuccessful { creditUnit() } markRunRow(item.key, outcome.isSuccessful ? .installedChecking : .failed)"))
        #expect(lanes.components(separatedBy: "markRunRow(item.key, .notStarted) return LaneItemResult(item: item, outcome: nil)").count - 1 == 2,
                "the cask gate and the npm gate")
        let updating = compact(try source("Sources/MacUpdater/ScanStore+Updating.swift"))
        #expect(updating.contains("defer { upgradeProgress = nil upgradeTracker = nil }"), "the pinned defer stays as it is")
        #expect(updating.contains("beginRunBoard(planned: plannedItems) defer { endRunBoard() }"))
        #expect(updating.contains("markCasksThatWillNotRun(plannedItems, trusted: caskLanePreparation?.trustedCaskNames ?? [])"))
    }

    /// A cask that never reaches `brew` must not keep reading „czeka” or „instaluję…” for the
    /// rest of the run: Docker Desktop refusing to stop fails the row, and a journal that
    /// cannot be written leaves every cask of the lane unstarted.
    @Test func aCaskThatNeverReachesBrewSaysWhyAtOnce() throws {
        let lanes = compact(try source("Sources/MacUpdater/ScanStore+UpgradeLanes.swift"))
        #expect(lanes.components(separatedBy: "markRunRow(item.key, .failed) return LaneItemResult(item: item, outcome: failure)").count - 1 == 3,
                "every Docker Desktop gate before and between the attempts")
        #expect(lanes.contains("reportJournalFailure(error) markCasksThatWillNotRun(items, trusted: []) return []"))
        #expect(lanes.contains("markRunLane(.formulae, .installing) let outcome = await runBrewUpgrade(arguments: arguments, logSource: \"brew\", streamsProgress: true) markRunLane(.formulae, outcome.isSuccessful ? .installedChecking : .failed)"))
        #expect(lanes.contains("markRunLane(.appStore, .notStarted) return ([], nil)"))
        #expect(lanes.contains("markRunLane(.appStore, .failed)"))
    }

    /// Once `postCaskUpgrade` has answered, a cask restored to its previous version, one whose
    /// restore failed and one brew never replaced stop reading „zainstalowano — sprawdzam”.
    @Test func aCaskThatFailsItsCheckOrNeverChangedReadsFailed() throws {
        let failing: [CaskValidationVerdict] = [
            .rolledBack, .publisherChangedAndRolledBack(old: "A", new: "B"), .rollbackFailed, .notUpgraded,
        ]
        let passing: [CaskValidationVerdict] = [
            .healthy, .publisherChanged(old: "A", new: "B"), .replacedByAppUpdater(version: "2"),
        ]
        #expect(failing.allSatisfy { $0.failsTheRunRow })
        #expect(!passing.contains { $0.failsTheRunRow })
        let lanes = compact(try source("Sources/MacUpdater/ScanStore+UpgradeLanes.swift"))
        #expect(lanes.contains("operation: operation ) if verdicts[token]?.failsTheRunRow == true { markRunRow(item.key, .failed) } "
                               + "if outcome.isSuccessful { creditUnit() }"))
    }

    @Test func boundariesThatChangeNothingPublishNothing() {
        let harness = makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: "", stderr: "")
        })
        let cask = OutdatedItem(key: "c:board-\(UUID().uuidString)", name: "board-cask", from: "1", to: "2", kind: .cask)
        let formula = OutdatedItem(key: "f:board-\(UUID().uuidString)", name: "board-formula", from: "1", to: "2", kind: .formula)
        harness.store.beginRunBoard(planned: [cask, formula])
        var publishes = 0
        let watch = harness.store.$runBoard.dropFirst().sink { _ in publishes += 1 }
        defer { watch.cancel() }

        harness.store.markRunRow(cask.key, .waiting)
        harness.store.markRunRow(formula.key, .installing)
        harness.store.markRunRow("c:not-planned", .installing)
        harness.store.markRunLane(.appStore, .installing)
        harness.store.markRunLane(.formulae, .waiting)
        harness.store.markCasksThatWillNotRun([cask, formula], trusted: [cask.name])
        #expect(publishes == 0, "a boundary that changes nothing republishes nothing")

        harness.store.markCasksThatWillNotRun([cask, formula], trusted: [])
        #expect(harness.store.runBoard.rows == [cask.key: .notStarted])
        #expect(harness.store.runBoard.lanes == [.formulae: .waiting])
        #expect(publishes == 1)
        harness.store.endRunBoard()
        harness.store.endRunBoard()
        #expect(harness.store.runBoard == .idle)
        #expect(publishes == 2)
    }

    // MARK: Fixtures

    private struct Keys {
        let all: Set<String>
        let npm: String
    }

    private enum StubError: Error {
        case npmUpgradeFailed
        case unexpected([String])
    }

    /// A formula, an App Store app and an npm package, run the way
    /// `ScanStoreRuntimeUpdatingTests` runs them; with `npmFails` the npm install stream throws.
    private static func harness(npmFails: Bool) -> (ScanStoreRuntimeHarness, Keys) {
        let formula = "board-formula-\(UUID().uuidString)"
        let package = "board-package-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
                case ["upgrade", "123"]:
                    return ProcessResult(exitCode: 0, stdout: "Updated Example App", stderr: "")
                case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                    return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
                case ["outdated"]:
                    return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                case ["outdated", "-g", "--json"]:
                    return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
                default:
                    throw StubError.unexpected(request.arguments)
                }
            },
            events: { request in
                switch request.arguments.first {
                case "upgrade":
                    return .success([
                        .stdout("Upgrading \(formula)\n"),
                        .finished(ProcessResult(exitCode: 0, stdout: "", stderr: "")),
                    ])
                case "install" where npmFails:
                    return .failure(StubError.npmUpgradeFailed)
                case "install":
                    return .success([
                        .stderr("npm notice installed \(package)\n"),
                        .finished(ProcessResult(exitCode: 0, stdout: "", stderr: "")),
                    ])
                default:
                    return .failure(StubError.unexpected(request.arguments))
                }
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")],
            casks: []
        )
        harness.store.masOutdated = [MasOutdatedApp(
            appStoreID: "123", name: "Example App", installedVersion: "1", currentVersion: "2"
        )]
        harness.store.npmOutdated = [NpmGlobalOutdated(name: package, installedVersion: "1", latestVersion: "2")]
        let items = harness.store.allItems
        let keys = Keys(all: Set(items.map(\.key)), npm: items.first { $0.kind == .npm }?.key ?? "")
        return (harness, keys)
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

    /// Collapses whitespace so a guard can assert on a code shape without pinning the
    /// indentation it happens to be written at.
    private func compact(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Every board the store published during a run, read back per row or per lane as the
/// sequence of different statuses it went through.
@MainActor
private final class BoardRecorder {
    var boards: [UpdateRunBoard] = []

    func rows(_ key: String) -> [UpdateRunRowStatus] { distinct(boards.map { $0.rows[key] }) }

    func lanes(_ lane: UpdateRunLane) -> [UpdateRunRowStatus] { distinct(boards.map { $0.lanes[lane] }) }

    private func distinct(_ statuses: [UpdateRunRowStatus?]) -> [UpdateRunRowStatus] {
        statuses.compactMap { $0 }.reduce(into: []) { sequence, status in
            if sequence.last != status { sequence.append(status) }
        }
    }
}
