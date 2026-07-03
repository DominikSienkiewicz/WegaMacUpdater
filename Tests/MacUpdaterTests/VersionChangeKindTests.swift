import XCTest
@testable import MacUpdaterCore

final class VersionChangeKindTests: XCTestCase {
    func testMajorBump()  { XCTAssertEqual(versionChangeKind(from: "1.2.3", to: "2.0.0"), .major) }
    func testMinorBump()  { XCTAssertEqual(versionChangeKind(from: "1.2.3", to: "1.3.0"), .minor) }
    func testPatchBump()  { XCTAssertEqual(versionChangeKind(from: "1.2.3", to: "1.2.4"), .patch) }
    func testFourthSegmentIsPatch() { XCTAssertEqual(versionChangeKind(from: "4.55.0", to: "4.55.0.1"), .patch) }
    func testEqualIsSame() { XCTAssertEqual(versionChangeKind(from: "125.0", to: "125.0.0"), .same) }
    func testZoomBuildFormatMajor() { XCTAssertEqual(versionChangeKind(from: "7.0.0 (77593)", to: "8.0.0 (80000)"), .major) }
    func testUnparseableIsUnknown() { XCTAssertEqual(versionChangeKind(from: "89d3ad2bf", to: "14263"), .unknown) }

    func testSecurityBeatsEverything() {
        XCTAssertEqual(versionEmphasis(changeKind: .major, isSecurityFix: true, requiresForce: true), .security)
    }
    func testForcedBeatsMajor() {
        XCTAssertEqual(versionEmphasis(changeKind: .major, isSecurityFix: false, requiresForce: true), .forced)
    }
    func testMajorWhenPlain() {
        XCTAssertEqual(versionEmphasis(changeKind: .major, isSecurityFix: false, requiresForce: false), .major)
    }
    func testNormalForPatch() {
        XCTAssertEqual(versionEmphasis(changeKind: .patch, isSecurityFix: false, requiresForce: false), .normal)
    }
}
