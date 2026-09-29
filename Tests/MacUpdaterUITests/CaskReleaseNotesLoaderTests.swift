import Foundation
import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class CaskReleaseNotesLoaderTests: XCTestCase {
    func testCancellationReturnsToIdleAndAllowsAnotherRequest() async throws {
        let notes = ReleaseNotes(html: "Changes", version: "2")
        let loader = CaskReleaseNotesLoader { _ in .notes(notes) }
        let request = try XCTUnwrap(CaskReleaseNotesRequest(
            item: OutdatedItem(key: "c:test", name: "test", from: "1", to: "2", kind: .cask),
            appPath: URL(fileURLWithPath: "/Applications/Test.app")
        ))
        let task = Task { await loader.loadIfNeeded(request) }
        task.cancel()
        await task.value
        XCTAssertEqual(loader.state, .idle)
        await loader.loadIfNeeded(request)
        XCTAssertEqual(loader.state, .loaded(notes))
    }

    func testConstructionDoesNotFetchAndRepeatedExpansionReusesNotes() async throws {
        var calls = 0
        let notes = ReleaseNotes(html: "Changes", version: "2")
        let loader = CaskReleaseNotesLoader { _ in calls += 1; return .notes(notes) }
        let request = try XCTUnwrap(CaskReleaseNotesRequest(
            item: OutdatedItem(key: "c:test", name: "test", from: "1", to: "2", kind: .cask),
            appPath: URL(fileURLWithPath: "/Applications/Test.app")
        ))
        XCTAssertEqual(calls, 0)
        await loader.loadIfNeeded(request)
        await loader.loadIfNeeded(request)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(loader.state, .loaded(notes))
    }

    func testFailureCanBeRetriedButMissingNotesAreNotCalledAConnectionFailure() async throws {
        var calls = 0
        let loader = CaskReleaseNotesLoader { _ in calls += 1; return calls == 1 ? .failed : .unavailable }
        let request = try XCTUnwrap(CaskReleaseNotesRequest(
            item: OutdatedItem(key: "c:test", name: "test", from: "1", to: "2", kind: .cask),
            appPath: URL(fileURLWithPath: "/Applications/Test.app")
        ))
        await loader.loadIfNeeded(request)
        XCTAssertEqual(loader.state, .failed)
        await loader.retry(request)
        XCTAssertEqual(loader.state, .unavailable)
        XCTAssertEqual(calls, 2)
    }
}
