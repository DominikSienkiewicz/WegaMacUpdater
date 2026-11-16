import XCTest
@testable import MacUpdaterCore

final class CleanupBucketPolicyTests: XCTestCase {
    private let process = CleanupProcess(pid: 42, name: "claude", executablePath: "/x/claude", arguments: [])

    private func bucket(
        _ status: CleanupStatus,
        source: CleanupSource? = nil,
        relation: CleanupVersionRelation = .notApplicable,
        recognisedLayout: Bool = true
    ) -> CleanupBucket {
        CleanupBucketPolicy.bucket(
            status: status, source: source, relation: relation, recognisedLayout: recognisedLayout
        )
    }

    private func finding(size: Int64?, bucket: CleanupBucket) -> CleanupFinding {
        CleanupFinding(
            detector: .versionDirectories, tool: "claude",
            path: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"), realpath: nil, source: nil,
            version: nil, size: size, status: .unused, reason: .unknownVersionDirectory,
            action: .none, risk: .low, bucket: bucket, identity: nil
        )
    }

    func testExcludedStatusesNeverCount() {
        let statuses: [CleanupStatus] = [
            .active, .expected, .appManaged, .dependency(["mlx"]), .info, .brokenLink, .skippedProtected
        ]
        for status in statuses {
            XCTAssertEqual(bucket(status), .excluded, "\(status)")
        }
    }

    func testInUseAlwaysNeedsDecision() {
        let source = CleanupSource.nativeVersionDirectory(tool: "claude")
        XCTAssertEqual(bucket(.inUse([process]), source: source), .needsDecision)
    }

    func testUnrecognisedOrManagerOwnedSourcesNeedDecision() {
        let sources: [(CleanupSource, Bool)] = [
            (.versionManager(.mise), true),
            (.packageManager(.npm), true),
            (.standalone, true),
            (.nativeVersionDirectory(tool: "claude"), false)
        ]
        for (source, recognised) in sources {
            XCTAssertEqual(
                bucket(.unused, source: source, recognisedLayout: recognised), .needsDecision, "\(source)"
            )
        }
    }

    func testShadowedHomebrewCopyIsSafeOnlyWhenNotNewer() {
        let source = CleanupSource.homebrewCask(token: "claude-code")
        XCTAssertEqual(bucket(.shadowed, source: source, relation: .olderOrSame), .safe)
        XCTAssertEqual(bucket(.shadowed, source: source, relation: .unknown), .needsDecision)
        XCTAssertEqual(bucket(.shadowed, source: source, relation: .newer), .needsDecision)
    }

    func testOldRecognisedVersionAndStaleShellEntryAreSafe() {
        let source = CleanupSource.nativeVersionDirectory(tool: "claude")
        XCTAssertEqual(bucket(.unused, source: source), .safe)
        XCTAssertEqual(bucket(.stale), .safe)
    }

    func testTotalsSkipExcludedFindings() {
        let findings = [
            finding(size: 307_000_000, bucket: .safe),
            finding(size: 300_000_000, bucket: .needsDecision),
            finding(size: 680_000_000, bucket: .excluded),
            finding(size: nil, bucket: .safe)
        ]
        XCTAssertEqual(
            CleanupTotals.sum(findings), CleanupTotals(safe: 307_000_000, needsDecision: 300_000_000)
        )
    }

    /// D8 reports a directory's stale entries and its kept entries as two findings for one path;
    /// SwiftUI lists and `CleanupStore.Phase.removing(findingID:)` need them told apart.
    func testFindingIDsDifferForStaleAndKeptShellStateFindings() {
        let directory = URL(filePath: "/Users/cleanup-test/.local/state/fnm_multishells", directoryHint: .isDirectory)
        func shellState(_ status: CleanupStatus, _ reason: CleanupReason) -> CleanupFinding {
            CleanupFinding(
                detector: .shellState, tool: "fnm", path: directory, realpath: nil, source: nil,
                version: nil, size: nil, status: status, reason: reason, action: .none, risk: .low,
                bucket: .excluded, identity: nil
            )
        }

        let stale = shellState(.stale, .staleSinceBoot(count: 2))
        let kept = shellState(.info, .keptSinceBoot(count: 3))

        XCTAssertNotEqual(stale.id, kept.id)
        XCTAssertEqual(stale.id, "D8:stale:/Users/cleanup-test/.local/state/fnm_multishells")
        XCTAssertEqual(kept.id, "D8:info:/Users/cleanup-test/.local/state/fnm_multishells")
        XCTAssertEqual(
            shellState(.inUse([process]), .staleSinceBoot(count: 1)).id,
            "D8:inUse:/Users/cleanup-test/.local/state/fnm_multishells",
            "associated values are not part of the id"
        )
    }

    func testProcessArgumentsAreNeverEncoded() throws {
        let original = CleanupProcess(pid: 7, name: "node", executablePath: "/x/node", arguments: ["--token=abc"])
        let data = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("abc"))
        XCTAssertEqual(try JSONDecoder().decode(CleanupProcess.self, from: data).arguments, [])
    }
}
