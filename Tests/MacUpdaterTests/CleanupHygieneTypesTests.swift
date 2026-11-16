import XCTest
@testable import MacUpdaterCore

final class CleanupHygieneTypesTests: XCTestCase {
    private func finding(
        detector: CleanupDetectorID, tool: String, path: String, status: CleanupStatus
    ) -> CleanupFinding {
        CleanupFinding(
            detector: detector, tool: tool, path: URL(filePath: path, directoryHint: .notDirectory), realpath: nil,
            source: nil, version: nil, size: nil, status: status, reason: .currentVersion, action: .none,
            risk: .low, bucket: .excluded, identity: nil
        )
    }

    func testMapIdsCarryTheTool() {
        let first = finding(detector: .tccMap, tool: "com.a", path: "/db/TCC.db", status: .info)
        let second = finding(detector: .tccMap, tool: "com.b", path: "/db/TCC.db", status: .info)
        let duplicate = finding(detector: .pathDuplicates, tool: "claude", path: "/p", status: .shadowed)

        XCTAssertEqual(first.id, "D10:info:/db/TCC.db:com.a")
        XCTAssertEqual(second.id, "D10:info:/db/TCC.db:com.b")
        XCTAssertEqual(duplicate.id, "D1:shadowed:/p")
        XCTAssertEqual(finding(detector: .pathHygiene, tool: "PATH", path: "/e", status: .deadEntry).id, "D9:deadEntry:/e")
    }

    func testTCCUtilNameDropsThePrefix() {
        XCTAssertEqual(CleanupTCCService.documents.tccutilName, "SystemPolicyDocumentsFolder")
    }

    func testNewReasonsRoundTripThroughJSON() throws {
        let reason = CleanupReason.tccEntry(
            grants: [CleanupTCCGrant(service: .documents, allowed: true)],
            link: CleanupTCCLink(findingID: "D1:active:/x", kind: .appManaged(owner: "Claude"))
        )
        let action = CleanupAction.instruction(
            .editShellFiles(entry: "/x", locations: [CleanupShellFileLocation(file: "/h/.zshrc", line: 42)])
        )

        XCTAssertEqual(try JSONDecoder().decode(CleanupReason.self, from: JSONEncoder().encode(reason)), reason)
        XCTAssertEqual(try JSONDecoder().decode(CleanupAction.self, from: JSONEncoder().encode(action)), action)
    }

    func testMapDefaults() {
        XCTAssertFalse(CleanupTCCMap.enabledByDefault)
        XCTAssertEqual(CleanupTCCMap.enabledKey, "cleanup.tccMap.enabled")
        XCTAssertEqual(
            CleanupTCCMap.fullDiskAccessPaneURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }
}
