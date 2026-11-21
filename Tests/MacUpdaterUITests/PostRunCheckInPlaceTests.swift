import Combine
import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// C2 stage 4 — the check that confirms a run used to take the window: `status` went to
/// `.checking` and the first-scan scene replaced the band, the list and the log mid-sentence.
/// It now runs in place under the result, like the launch refresh, and so does the undo's. The
/// toolbar no longer offers an „Anuluj” that cancels nothing: neither check runs in `scanTask`.
@Suite("Post-run check in place") @MainActor
struct PostRunCheckInPlaceTests {
    private enum StubError: Error {
        case unexpected([String])
    }

    /// What the store published while the run worked.
    @MainActor
    private final class Recorder {
        var statuses: [UpdateStatus] = []
        /// `(isRefreshing, updating)` each time `isRefreshing` was published.
        var refreshes: [(refreshing: Bool, updating: Bool)] = []
    }

    @Test func aRunNeverHandsTheWindowToTheScan() async throws {
        let formula = "in-place-formula-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
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
                guard request.arguments.first == "upgrade" else { return .failure(StubError.unexpected(request.arguments)) }
                return .success([
                    .stdout("Upgrading \(formula)\n"),
                    .finished(ProcessResult(exitCode: 0, stdout: "", stderr: "")),
                ])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        let store = harness.store
        store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")],
            casks: []
        )
        store.lastCheck = Date(timeIntervalSince1970: 1_700_000_000)
        store.status = .results
        let key = try #require(store.allItems.first { $0.name == formula }).key
        let recorder = Recorder()
        let statusWatch = store.$status.sink { recorder.statuses.append($0) }
        let refreshWatch = store.$isRefreshing.sink { refreshing in
            recorder.refreshes.append((refreshing, store.updating))
        }
        defer {
            statusWatch.cancel()
            refreshWatch.cancel()
        }

        await store.runUpdate(targetKeys: [key])

        #expect(!recorder.statuses.contains(.checking), "the check after the run never takes the window: \(recorder.statuses)")
        #expect(recorder.refreshes.contains { $0.refreshing && $0.updating },
                "the check runs under the result while the run still holds it")
        #expect(store.status == .results)
        #expect(!store.isRefreshing)
        #expect(!store.updating)
        #expect(store.runReport?.status == .finished, "the check confirmed the run")
    }

    @Test func anUndoOverAResultChecksInPlace() throws {
        let undo = try source("Sources/MacUpdater/ScanStore+Undo.swift")
        let call = try #require(undo.range(of: "await runCheck("), "the undo still confirms itself with a check")
        let line = undo[call.lowerBound...].prefix { $0 != "\n" }
        #expect(line.contains("quiet: scansInPlace"), "\(line)")
        #expect(undo.components(separatedBy: "await runCheck(").count == 2, "one check after an undo")
    }

    @Test func theToolbarOffersAnulujOnlyForACancellableScan() throws {
        let control = try source("Sources/MacUpdater/ScanControl.swift")
        #expect(control.contains("if scan.canCancelScan {"))
        #expect(control.contains(".disabled(!scan.canStartCheck)"))
        #expect(!control.contains("scan.status == .checking || scan.isRefreshing"),
                "„Anuluj” follows what `cancelScan()` can stop, not every scan on screen")
        #expect(!control.contains(".disabled(scan.updating)"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
