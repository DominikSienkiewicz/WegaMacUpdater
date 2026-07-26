import XCTest
@testable import MacUpdaterCore

/// UX-06 — the readiness screen and the results stamp are generated from the sources a scan
/// actually covers, never a hardcoded "brew + mas". This pins the pure selection logic:
/// which sources count as *active* given a scan's per-source picture, so npm and the manual
/// checkers can no longer be silently dropped from the message.
final class ScanSourceTests: XCTestCase {
    func testEveryAnsweringSourceIsActiveInScanOrderIncludingNpmAndManual() {
        let reports = ScanSourceReports(
            brew: ScanSourceReport(outcome: .succeeded),
            mas: ScanSourceReport(outcome: .succeeded),
            npm: ScanSourceReport(outcome: .succeeded),
            manual: ScanSourceReport(outcome: .succeeded)
        )
        XCTAssertEqual(ScanSource.active(in: reports), [.homebrew, .appStore, .npm, .manual])
    }

    /// An uninstalled tool is "not applicable" (F4), so it is not an active source.
    func testAnUninstalledSourceIsNotActive() {
        let reports = ScanSourceReports(
            brew: ScanSourceReport(outcome: .succeeded),
            mas: ScanSourceReport(outcome: .notInstalled),
            npm: ScanSourceReport(outcome: .succeeded)
        )
        XCTAssertEqual(ScanSource.active(in: reports), [.homebrew, .npm])
    }

    /// A source that was present and went silent still took part in the scan — the result
    /// covers it, so the stamp must keep naming it; the banner says separately it failed.
    func testAPresentButSilentSourceStaysActive() {
        let reports = ScanSourceReports(
            brew: ScanSourceReport(outcome: .failed("brew outdated")),
            npm: ScanSourceReport(outcome: .succeeded)
        )
        XCTAssertEqual(ScanSource.active(in: reports), [.homebrew, .npm])
    }

    /// The regression this card is about: whenever npm answered, npm is an active source.
    func testNpmIsActiveWheneverItAnswered() {
        let reports = ScanSourceReports(npm: ScanSourceReport(outcome: .succeeded))
        XCTAssertTrue(ScanSource.active(in: reports).contains(.npm))
    }

    /// No per-source detail at all (a legacy snapshot / background-agent result) yields no
    /// active source — the caller falls back to naming the sources Wega checks.
    func testMissingReportsYieldNoActiveSources() {
        XCTAssertEqual(ScanSource.active(in: ScanSourceReports()), [])
    }
}
