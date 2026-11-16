import XCTest
@testable import MacUpdaterCore

final class CleanupVersionDirectoryDetectorTests: XCTestCase {
    private var tmp: CleanupTempHome!
    private var fileSystem: CleanupFileSystem!

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        fileSystem = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(trash: { _ in }),
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
    }

    private let emptyScan = CleanupPathScan(groups: [], skippedProtected: [], missingDirectories: [])

    private func findings(
        scan: CleanupPathScan? = nil, processes: [CleanupProcess] = []
    ) -> [CleanupFinding] {
        CleanupVersionDirectoryDetector(
            fileSystem: fileSystem, home: tmp.home,
            inspector: FakeProcessInspector(processes: processes, bootTime: Date(timeIntervalSince1970: 0))
        ).findings(pathScan: scan ?? emptyScan)
    }

    private func installClaude(versions: [String], current: String?) throws {
        for version in versions {
            try tmp.file(".local/share/claude/versions/\(version)", size: 4096, executable: true)
        }
        if let current {
            try tmp.symlink(".local/bin/claude", to: tmp.url(".local/share/claude/versions/\(current)").path)
        }
    }

    private func finding(_ version: String, in all: [CleanupFinding], line: UInt = #line) throws -> CleanupFinding {
        try XCTUnwrap(all.first { $0.version == version }, "no finding for \(version)", line: line)
    }

    func testOldVersionsAreUnusedAndTheCurrentOneIsActive() throws {
        try installClaude(versions: ["2.1.318", "2.1.322", "2.1.325"], current: "2.1.325")

        let all = findings().filter { $0.detector == .versionDirectories && $0.status != .appManaged }

        XCTAssertEqual(all.count, 3)
        let current = try finding("2.1.325", in: all)
        XCTAssertEqual(current.status, .active)
        XCTAssertEqual(current.action, .none)
        XCTAssertEqual(current.bucket, .excluded)
        for old in ["2.1.318", "2.1.322"] {
            let item = try finding(old, in: all)
            XCTAssertEqual(item.status, .unused)
            XCTAssertEqual(item.action, .trash([tmp.url(".local/share/claude/versions/\(old)")]))
            XCTAssertEqual(item.reason, .olderVersion(current: "2.1.325"))
            XCTAssertEqual(item.bucket, .safe)
            XCTAssertEqual(item.risk, .low)
            XCTAssertEqual(item.tool, "claude")
            XCTAssertEqual(item.source, .nativeVersionDirectory(tool: "claude"))
            XCTAssertGreaterThan(item.size ?? 0, 0)
            XCTAssertNotNil(item.identity)
        }
    }

    func testVersionExecutedByARunningProcessIsInUse() throws {
        try installClaude(versions: ["2.1.318", "2.1.325"], current: "2.1.325")
        let old = tmp.url(".local/share/claude/versions/2.1.318").path
        let process = CleanupProcess(
            pid: 4242, name: "claude", executablePath: old, arguments: [old, "--chrome-native-host"]
        )

        let item = try finding("2.1.318", in: findings(processes: [process]))

        XCTAssertEqual(item.status, .inUse([process]))
        XCTAssertEqual(item.risk, .high)
        XCTAssertEqual(item.bucket, .needsDecision)
        guard case .inUse(let users) = item.status else { return XCTFail("not in use") }
        XCTAssertEqual(users.first?.arguments, [old, "--chrome-native-host"])
    }

    func testMissingPointerMakesTheLayoutUnrecognised() throws {
        try installClaude(versions: ["2.1.318", "2.1.325"], current: nil)

        let all = findings().filter { $0.status != .appManaged }

        XCTAssertEqual(all.count, 2)
        for item in all {
            XCTAssertEqual(item.status, .unused)
            XCTAssertEqual(item.action, .instruction(.removeWithCreatingTool))
            XCTAssertEqual(item.bucket, .needsDecision)
        }
    }

    func testPathCopyInsideTheVersionsDirectoryMarksItActive() throws {
        try installClaude(versions: ["2.1.318", "2.1.325"], current: nil)
        let target = try fileSystem.realpath(tmp.url(".local/share/claude/versions/2.1.325"))
        let copy = CleanupCopy(
            path: tmp.url(".local/bin/claude"), realpath: target, pathIndex: 0,
            source: .nativeVersionDirectory(tool: "claude"), version: "2.1.325",
            identity: CleanupFileIdentity(device: 1, inode: 1), role: .active
        )
        let scan = CleanupPathScan(
            groups: [CleanupToolGroup(name: "claude", copies: [copy])], skippedProtected: [], missingDirectories: []
        )

        let all = findings(scan: scan)

        XCTAssertEqual(try finding("2.1.325", in: all).status, .active)
        XCTAssertEqual(try finding("2.1.318", in: all).action, .trash([tmp.url(".local/share/claude/versions/2.1.318")]))
    }

    func testAppManagedCopiesAreReportedWithoutAction() throws {
        try tmp.file("Library/Application Support/Claude/claude-code/2.1.1/claude", size: 1_048_576)
        try tmp.file("Library/Application Support/Claude/claude-code-vm/2.1.1/claude", size: 1_048_576)

        let all = findings()

        XCTAssertEqual(all.count, 2)
        for item in all {
            XCTAssertEqual(item.status, .appManaged)
            XCTAssertEqual(item.action, .none)
            XCTAssertEqual(item.bucket, .excluded)
            XCTAssertEqual(item.reason, .managedByApp(owner: "Claude"))
            XCTAssertEqual(item.source, .appManaged(owner: "Claude"))
            XCTAssertGreaterThan(item.size ?? 0, 0)
        }
    }

    func testUnknownVersionDirectoryNeverGetsTrash() throws {
        let one = try tmp.file("tools/foo/versions/1.0", size: 100, executable: true)
        let two = try tmp.file("tools/foo/versions/2.0", size: 100, executable: true)
        try tmp.symlink("bin/foo", to: two.path)
        let copy = CleanupCopy(
            path: tmp.url("bin/foo"), realpath: two, pathIndex: 0, source: .standalone, version: nil,
            identity: CleanupFileIdentity(device: 1, inode: 1), role: .active
        )
        let scan = CleanupPathScan(
            groups: [CleanupToolGroup(name: "foo", copies: [copy])], skippedProtected: [], missingDirectories: []
        )

        let all = findings(scan: scan)

        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(try finding("2.0", in: all).status, .active)
        XCTAssertEqual(try finding("2.0", in: all).bucket, .excluded)
        let old = try finding("1.0", in: all)
        XCTAssertEqual(old.status, .unused)
        XCTAssertEqual(old.action, .instruction(.removeWithCreatingTool))
        XCTAssertEqual(old.reason, .unknownVersionDirectory)
        XCTAssertEqual(old.bucket, .needsDecision)
        XCTAssertEqual(old.tool, "foo")
        XCTAssertEqual(old.path, one)
    }

    func testHeuristicNeedsTwoVersionLikeSiblings() throws {
        let lone = try tmp.file("tools/bar/versions/1.0", size: 10, executable: true)
        try tmp.file("tools/bar/versions/latest", size: 10)
        let pair = try tmp.file("tools/baz/v1.2.0/bin/baz", size: 10, executable: true)
        try tmp.file("tools/baz/v1.3.0/bin/baz", size: 10)

        XCTAssertNil(CleanupVersionDirectoryDetector.heuristicVersionDirectory(containing: lone, fileSystem: fileSystem))
        XCTAssertEqual(
            CleanupVersionDirectoryDetector.heuristicVersionDirectory(containing: pair, fileSystem: fileSystem)?.path,
            tmp.url("tools/baz").path
        )
    }
}
