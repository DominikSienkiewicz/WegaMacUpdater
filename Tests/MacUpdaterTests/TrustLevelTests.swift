import XCTest
@testable import MacUpdaterCore

final class TrustLevelTests: XCTestCase {

    // MARK: - `.unavailable` (all nil)

    func testAllNilReturnsUnavailable() {
        let result = trustLevel(audit: nil, signatureValid: nil, caskChecksumPresent: nil)
        XCTAssertEqual(result, .unavailable)
    }

    // MARK: - `.warning` (changed audit)

    func testChangedAuditReturnsWarning() {
        let result = trustLevel(audit: .changed(old: "A", new: "B"), signatureValid: nil, caskChecksumPresent: nil)
        XCTAssertEqual(result, .warning)
    }

    // MARK: - `.warning` (invalid signature)

    func testInvalidSignatureReturnsWarning() {
        let result = trustLevel(audit: nil, signatureValid: false, caskChecksumPresent: nil)
        XCTAssertEqual(result, .warning)
    }

    // MARK: - `.warning` (missing cask checksum)

    func testMissingCaskChecksumReturnsWarning() {
        let result = trustLevel(audit: nil, signatureValid: nil, caskChecksumPresent: false)
        XCTAssertEqual(result, .warning)
    }

    // MARK: - `.ok` (safe combinations)

    func testUnchangedAuditWithValidSignatureAndNoChecksum() {
        let result = trustLevel(audit: .unchanged(teamID: "X"), signatureValid: true, caskChecksumPresent: nil)
        XCTAssertEqual(result, .ok)
    }

    func testFirstSeenAuditWithValidSignatureAndChecksum() {
        let result = trustLevel(audit: .firstSeen(teamID: "X"), signatureValid: true, caskChecksumPresent: true)
        XCTAssertEqual(result, .ok)
    }
}
