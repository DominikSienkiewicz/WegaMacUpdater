import Foundation
import XCTest
import MacUpdaterCore

@testable import WegaMacUpdater

/// UX-06 — the readiness screen and the results stamp must be generated from the sources a
/// scan actually covers (npm and the manual checkers included), not the frozen "brew + mas".
///
/// The card's regression: *with npm active, the readiness screen and the stamp name it.*
final class SourceCommunicationTests: XCTestCase {
    private func packageRoot(file: String = #filePath) -> URL {
        // <root>/Tests/MacUpdaterUITests/<thisFile>.swift → up 3 = <root>
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: Readiness screen

    func testReadyMessageNamesEverySourceWegaChecksIncludingNpmAndManual() {
        let message = SourceCommunication.readyMessage(for: ScanSource.allCases)
        XCTAssertTrue(message.contains("npm"), "the readiness screen must name npm: \(message)")
        XCTAssertTrue(message.contains("Homebrew"), message)
        XCTAssertTrue(message.contains("Mac App Store"), message)
        XCTAssertTrue(
            message.contains(SourceCommunication.readyName(.manual)),
            "the readiness screen must name the manual checkers: \(message)"
        )
    }

    // MARK: Results stamp

    func testStampNamesNpmWhenNpmIsAmongTheActiveSources() {
        let stamp = SourceCommunication.stamp(for: [.homebrew, .appStore, .npm])
        XCTAssertTrue(stamp.contains("npm"), "the stamp must name npm when it is active: \(stamp)")
        XCTAssertTrue(stamp.contains("brew"), stamp)
        XCTAssertTrue(stamp.contains("mas"), stamp)
    }

    /// Proof the stamp is generated, not a relabeled constant: a scan without npm must not
    /// name it, and one covering only Homebrew must not claim Mac App Store.
    func testStampOmitsSourcesThatWereNotActive() {
        XCTAssertFalse(SourceCommunication.stamp(for: [.homebrew, .appStore]).contains("npm"))
        XCTAssertFalse(SourceCommunication.stamp(for: [.homebrew]).contains("mas"))
    }

    func testStampIsDerivedFromActiveSourcesEndToEnd() {
        let reports = ScanSourceReports(
            brew: ScanSourceReport(outcome: .succeeded),
            mas: ScanSourceReport(outcome: .notInstalled),
            npm: ScanSourceReport(outcome: .succeeded),
            manual: ScanSourceReport(outcome: .succeeded)
        )
        let stamp = SourceCommunication.stamp(for: ScanSource.active(in: reports))
        XCTAssertTrue(stamp.contains("npm"), stamp)
        XCTAssertTrue(stamp.contains("brew"), stamp)
        XCTAssertFalse(stamp.contains("mas"), "an uninstalled Mac App Store must not be stamped: \(stamp)")
    }

    /// The frozen "brew + mas" literal the card calls out must be gone from the view.
    func testTheHardcodedBrewPlusMasStampIsGone() throws {
        let updateView = try source("Sources/MacUpdater/UpdateView.swift")
        XCTAssertFalse(updateView.contains("\"brew + mas\""),
                       "UX-06: the results stamp must be generated from active sources")
    }
}
