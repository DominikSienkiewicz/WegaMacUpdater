import XCTest
@testable import MacUpdaterCore

/// F4 — "Homebrew is not installed" is not "Homebrew failed to answer".
///
/// A missing `brew` binary used to throw into the same catch as a network error, so a user
/// without Homebrew saw a permanent red "the list may be incomplete" banner over a list
/// that was, in fact, complete for the sources they actually have. An absent tool is *not
/// applicable*; a present tool that went silent is a failure. Only the second may paint the
/// scan red — and only the first earns a "install Homebrew to unlock N more" card.
final class SourceAvailabilityTests: XCTestCase {
    func testAnUninstalledToolIsNotCountedAsAFailure() {
        let failures = UpdatePlanner.failedSourceCount([.succeeded, .notInstalled, .succeeded])
        XCTAssertEqual(failures, 0)
    }

    func testASilentToolIsCountedAsAFailure() {
        let failures = UpdatePlanner.failedSourceCount([.succeeded, .failed("brew outdated")])
        XCTAssertEqual(failures, 1)
    }

    func testUninstalledAndFailedAreCountedSeparately() {
        let outcomes: [SourceCheckOutcome] = [.notInstalled, .failed("npm"), .notInstalled, .failed("mas")]
        XCTAssertEqual(UpdatePlanner.failedSourceCount(outcomes), 2)
        XCTAssertEqual(UpdatePlanner.unavailableSourceCount(outcomes), 2)
    }

    /// The names feed the scan log, so a silent source can be named and an absent one isn't.
    func testOnlyFailedSourcesAreNamed() {
        let outcomes: [SourceCheckOutcome] = [.notInstalled, .failed("brew outdated"), .succeeded]
        XCTAssertEqual(UpdatePlanner.failedSourceNames(outcomes), ["brew outdated"])
    }

    /// The whole point: no Homebrew, updates found elsewhere → a clean, non-red result.
    func testMissingBrewWithFindingsElsewhereReadsAsPlainOutdated() {
        let outcomes: [SourceCheckOutcome] = [.notInstalled, .succeeded]
        let state = UpdatePlanner.scanState(
            updateCount: 5,
            failedChecks: UpdatePlanner.failedSourceCount(outcomes)
        )
        XCTAssertEqual(state, .outdated(5))
    }

    /// And with nothing found: "up to date", not "couldn't check".
    func testMissingBrewWithNoFindingsReadsAsUpToDate() {
        let outcomes: [SourceCheckOutcome] = [.notInstalled, .succeeded]
        let state = UpdatePlanner.scanState(
            updateCount: 0,
            failedChecks: UpdatePlanner.failedSourceCount(outcomes)
        )
        XCTAssertEqual(state, .upToDate)
    }

    /// A real failure alongside an absent tool still fails.
    func testSilentSourceStillFailsEvenWhenAnotherToolIsAbsent() {
        let outcomes: [SourceCheckOutcome] = [.notInstalled, .failed("mas")]
        let state = UpdatePlanner.scanState(
            updateCount: 3,
            failedChecks: UpdatePlanner.failedSourceCount(outcomes)
        )
        XCTAssertEqual(state, .partialFailure(updates: 3, failed: 1))
    }
}
