import XCTest
@testable import MacUpdaterCore

/// M2(c) — the "checking" screen used to animate five fake command bars on a timer while
/// the real scan did something else entirely, for as long as it took, with no way to stop
/// it. The scan is in fact strictly sequential — brew, then mas, then npm, then the manual
/// checkers — so real progress is expressible, and it is.
final class ScanPhaseTests: XCTestCase {
    func testPhasesRunInTheOrderTheScanActuallyRunsThem() {
        XCTAssertEqual(ScanPhase.allCases, [.brew, .mas, .npm, .manual])
    }

    func testProgressStartsAtZeroForTheFirstPhase() {
        XCTAssertEqual(ScanPhase.brew.fractionCompleted, 0, accuracy: 0.001)
    }

    /// Progress reports what is *finished*, so the last phase is not 100% while it runs.
    func testTheFinalPhaseIsNotYetComplete() {
        XCTAssertEqual(ScanPhase.manual.fractionCompleted, 0.75, accuracy: 0.001)
    }

    func testEachPhaseAdvancesProgressByAnEqualShare() {
        XCTAssertEqual(ScanPhase.mas.fractionCompleted, 0.25, accuracy: 0.001)
        XCTAssertEqual(ScanPhase.npm.fractionCompleted, 0.5, accuracy: 0.001)
    }

    func testFinishedScanReportsFullProgress() {
        XCTAssertEqual(ScanProgress.finished.fractionCompleted, 1, accuracy: 0.001)
    }

    func testRunningScanReportsItsPhasesProgress() {
        XCTAssertEqual(ScanProgress.running(.npm).fractionCompleted, 0.5, accuracy: 0.001)
    }

    /// A cancelled scan freezes wherever it stopped; it must not read as complete.
    func testCancelledScanKeepsThePhaseItStoppedAt() {
        XCTAssertEqual(ScanProgress.cancelled(at: .mas).fractionCompleted, 0.25, accuracy: 0.001)
    }

    func testOnlyARunningScanIsCancellable() {
        XCTAssertTrue(ScanProgress.running(.brew).isCancellable)
        XCTAssertFalse(ScanProgress.finished.isCancellable)
        XCTAssertFalse(ScanProgress.cancelled(at: .brew).isCancellable)
    }

    /// Each phase names the source it is querying, so the screen can stop pretending.
    func testEveryPhaseNamesItsSource() {
        XCTAssertEqual(ScanPhase.brew.commandLabel, "brew outdated")
        XCTAssertEqual(ScanPhase.mas.commandLabel, "mas outdated")
        XCTAssertEqual(ScanPhase.npm.commandLabel, "npm outdated -g")
        XCTAssertEqual(ScanPhase.manual.commandLabel, "sparkle · cask check")
    }
}
