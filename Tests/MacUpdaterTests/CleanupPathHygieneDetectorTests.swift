import XCTest
@testable import MacUpdaterCore

final class CleanupPathHygieneDetectorTests: XCTestCase {
    private var tmp: CleanupTempHome!
    private var recording: RecordingCleanupFileSystem!
    private var etc: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        tmp = try CleanupTempHome()
        etc = try tmp.directory("etc")
        recording = RecordingCleanupFileSystem(wrapping: LiveCleanupFileSystem(trash: { _ in }))
    }

    private func snapshot(_ entries: [String], approximate: Bool = false) -> CleanupPathSnapshot {
        CleanupPathSnapshot(entries: entries, ignoredEntries: [], shell: "zsh", capturedAt: nil, isApproximate: approximate)
    }

    private func scan(
        _ entries: [String], duplicates: [CleanupFinding] = [], approximate: Bool = false
    ) -> (findings: [CleanupFinding], skippedProtected: [String]) {
        let guarded = GuardedCleanupFileSystem(
            base: recording,
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
        return CleanupPathHygieneDetector(fileSystem: guarded, home: tmp.home, systemConfigurationDirectory: etc)
            .scan(snapshot(entries, approximate: approximate), duplicates: duplicates)
    }

    private func editLocations(_ finding: CleanupFinding) -> [CleanupShellFileLocation]? {
        guard case .instruction(.editShellFiles(_, let locations)) = finding.action else { return nil }
        return locations
    }

    func testBriefCase13DeadEntriesAreAttributed() throws {
        let framework = tmp.url("Library/Frameworks/Python.framework/Versions/3.11/bin").path
        let pkg = tmp.url("pkg/env/global/bin").path
        try tmp.file(".zprofile", text: "# setup\n\nexport PATH=\(framework):$PATH\n")

        let result = scan([framework, pkg])

        XCTAssertEqual(result.findings.map(\.status), [.deadEntry, .deadEntry])
        XCTAssertEqual(result.findings.map(\.reason), [.missingPathEntry, .missingPathEntry])
        XCTAssertEqual(result.findings.map(\.bucket), [.excluded, .excluded])
        XCTAssertEqual(result.findings.map(\.size), [nil, nil])
        XCTAssertEqual(result.findings.map(\.detector), [.pathHygiene, .pathHygiene])
        XCTAssertEqual(result.findings.map(\.tool), ["PATH", "PATH"])
        XCTAssertEqual(editLocations(result.findings[0]), [CleanupShellFileLocation(file: tmp.url(".zprofile").path, line: 3)])
        XCTAssertEqual(editLocations(result.findings[1]), [])
    }

    func testBriefCase14NestedEntry() throws {
        let parent = try tmp.directory("Library/pnpm").path
        let child = try tmp.directory("Library/pnpm/bin").path

        let result = scan([parent, child])

        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings[0].path.path, child)
        XCTAssertEqual(result.findings[0].status, .info)
        XCTAssertEqual(result.findings[0].reason, .nestedIn(parent: parent))
        XCTAssertEqual(result.findings[0].realpath?.path, child)
    }

    func testNestedComparesWholeComponentsNotStringPrefixes() throws {
        let first = try tmp.directory("tools").path
        let second = try tmp.directory("tools2/bin").path

        XCTAssertEqual(scan([first, second]).findings, [])
    }

    func testRepeatedEntryIsReportedOnce() throws {
        let first = try tmp.directory("a").path
        let second = try tmp.directory("b").path

        let result = scan([first, second, first, first])

        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings[0].path.path, first)
        XCTAssertEqual(result.findings[0].reason, .repeatedPathEntry(count: 3))
    }

    func testSymlinkedEntryIsSamePlace() throws {
        let real = try tmp.directory("bin").path
        let link = try tmp.symlink("bin-link", to: real).path

        let result = scan([real, link])

        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings[0].path.path, link)
        XCTAssertEqual(result.findings[0].reason, .samePlaceAs(path: real))
        XCTAssertEqual(result.findings[0].realpath?.path, real)
    }

    func testTrailingSlashSpellingIsSamePlace() throws {
        let bin = try tmp.directory("bin").path

        let result = scan([bin, bin + "/"])

        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings[0].reason, .samePlaceAs(path: bin))
    }

    func testFileOnPathIsDead() throws {
        let file = try tmp.file("notadir").path

        let result = scan([file])

        XCTAssertEqual(result.findings.map(\.status), [.deadEntry])
        XCTAssertNotNil(result.findings[0].identity)
        XCTAssertNil(result.findings[0].realpath)
    }

    func testBrokenLinkOnPathIsDead() throws {
        let link = try tmp.symlink("gone", to: tmp.url("nowhere").path).path

        let findings = scan([link]).findings

        XCTAssertEqual(findings.map(\.status), [.deadEntry])
        let linkIdentity = try XCTUnwrap(LiveCleanupFileSystem(trash: { _ in }).entry(at: URL(filePath: link))).identity
        XCTAssertEqual(findings[0].identity, linkIdentity)
    }

    func testHealthyDistinctEntriesProduceNothing() throws {
        XCTAssertEqual(scan([try tmp.directory("a").path, try tmp.directory("b").path]).findings, [])
    }

    private func duplicate(
        _ status: CleanupStatus, _ relative: String, version: String?, tool: String = "claude"
    ) -> CleanupFinding {
        CleanupFinding(
            detector: .pathDuplicates, tool: tool, path: tmp.url(relative), realpath: tmp.url(relative),
            source: .standalone, version: version, size: nil, status: status, reason: .currentVersion,
            action: .none, risk: .low, bucket: .needsDecision, identity: nil
        )
    }

    func testOlderCopyWins() throws {
        try tmp.file(".zshrc", text: "export PATH=\(tmp.url(".local/bin").path):$PATH\n")
        let findings = [
            duplicate(.active, ".local/bin/claude", version: "2.1.300"),
            duplicate(.shadowed, "opt/homebrew/bin/claude", version: "2.1.311"),
        ]

        let result = scan([], duplicates: findings)

        XCTAssertEqual(result.findings.count, 1)
        let finding = result.findings[0]
        XCTAssertEqual(finding.status, .info)
        XCTAssertEqual(finding.tool, "claude")
        XCTAssertEqual(finding.path, tmp.url(".local/bin/claude"))
        XCTAssertEqual(finding.version, "2.1.300")
        XCTAssertEqual(finding.reason, .olderCopyWins(
            version: "2.1.300", newer: tmp.url("opt/homebrew/bin/claude").path, newerVersion: "2.1.311"
        ))
        XCTAssertEqual(
            finding.action,
            .instruction(.editShellFiles(
                entry: tmp.url(".local/bin").path,
                locations: [CleanupShellFileLocation(file: tmp.url(".zshrc").path, line: 1)]
            ))
        )
    }

    func testOlderCopyDoesNotWinWithoutAStrictlyNewerKnownVersion() {
        for shadowed in [nil, "2.1.300", "2.1.299"] as [String?] {
            let findings = [
                duplicate(.active, ".local/bin/claude", version: "2.1.300"),
                duplicate(.shadowed, "opt/homebrew/bin/claude", version: shadowed),
            ]
            XCTAssertEqual(scan([], duplicates: findings).findings, [], "shadowed version \(shadowed ?? "nil")")
        }
        let unknownActive = [
            duplicate(.active, ".local/bin/claude", version: nil),
            duplicate(.shadowed, "opt/homebrew/bin/claude", version: "2.1.311"),
        ]
        XCTAssertEqual(scan([], duplicates: unknownActive).findings, [])
    }

    func testOlderCopyIgnoresExpectedBrokenAndProtectedCopies() {
        let findings = [
            duplicate(.active, ".local/bin/claude", version: "1.0.0"),
            duplicate(.expected, "usr/bin/claude", version: "9.0.0"),
            duplicate(.brokenLink, "x/claude", version: "9.0.0"),
            duplicate(.skippedProtected, "y/claude", version: "9.0.0"),
        ]
        XCTAssertEqual(scan([], duplicates: findings).findings, [])
    }

    func testApproximatePathTouchesNothing() throws {
        let result = scan([tmp.url("missing").path], approximate: true)

        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.skippedProtected, [])
        XCTAssertEqual(recording.touched, [])
    }

    func testProtectedEntryIsLeftToD1() throws {
        try tmp.directory("Documents/bin")

        let result = scan([tmp.url("Documents/bin").path])

        XCTAssertEqual(result.findings, [])
        XCTAssertFalse(recording.touched.contains { $0.hasPrefix(tmp.home.path + "/Documents") })
    }

    func testRelativeAndNULEntriesAreIgnored() {
        XCTAssertEqual(scan(["relative/bin", "/a\u{0}b"]).findings, [])
    }

    func testShellLineTextNeverLeaks() throws {
        let dead = tmp.url("gone/bin").path
        try tmp.file(".zshrc", text: "export TOKEN=SENTINEL_9f3; export PATH=\(dead):$PATH\n")

        let findings = scan([dead]).findings

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(editLocations(findings[0])?.count, 1)
        XCTAssertFalse(String(describing: findings).contains("SENTINEL_9f3"))
        let report = CleanupReport(
            createdAt: Date(timeIntervalSince1970: 0), path: snapshot([dead]), findings: findings,
            notes: [], skippedProtected: []
        )
        let json = String(decoding: try CleanupReportRenderer.json(report, home: tmp.home), as: UTF8.self)
        XCTAssertFalse(json.contains("SENTINEL_9f3"))
    }

    /// `/etc/paths.d/10-cryptex` is Apple's, restored by every OS update, and its directories often
    /// do not exist. Nothing on disk exists here, so every other entry is dead; the detector's own
    /// calls are recorded above the guard, which shows the cryptex entries are never looked at.
    func testMacOSCryptexEntriesAreNeverFindings() {
        let cryptex = "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr"
        let entries = [
            cryptex + "/local/bin", cryptex + "/bin", cryptex + "/appleinternal/bin",
            "/private" + cryptex + "/bin", "/var/run/com.apple.security.cryptexd", cryptex + "/bin",
            "/var/run/com.apple.security.cryptexd2/bin", "/private/var/run/other/bin",
        ]
        let direct = RecordingCleanupFileSystem(wrapping: GuardedCleanupFileSystem(
            base: NothingOnDiskFileSystem(),
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        ))
        let detector = CleanupPathHygieneDetector(fileSystem: direct, home: tmp.home, systemConfigurationDirectory: etc)
        let olderActiveInCryptex = [
            CleanupFinding(
                detector: .pathDuplicates, tool: "tool", path: URL(filePath: cryptex + "/bin/tool", directoryHint: .notDirectory),
                realpath: nil, source: .system, version: "1.0.0", size: nil, status: .active, reason: .currentVersion,
                action: .none, risk: .low, bucket: .excluded, identity: nil
            ),
            duplicate(.shadowed, "opt/homebrew/bin/tool", version: "2.0.0", tool: "tool"),
        ]

        let findings = detector.scan(snapshot(entries), duplicates: olderActiveInCryptex).findings

        XCTAssertEqual(findings.map(\.path.path), ["/var/run/com.apple.security.cryptexd2/bin", "/private/var/run/other/bin"])
        XCTAssertEqual(findings.map(\.reason), [.missingPathEntry, .missingPathEntry])
        let cryptexRoots = [["var", "run", "com.apple.security.cryptexd"], ["private", "var", "run", "com.apple.security.cryptexd"]]
        let touchedCryptex = direct.touched.filter { path in
            cryptexRoots.contains { CleanupPathText.components(of: path).starts(with: $0) }
        }
        XCTAssertEqual(touchedCryptex, [], "a cryptex entry is never looked at")
    }

    func testIdsAreUnique() throws {
        let repeated = try tmp.directory("a").path
        let parent = try tmp.directory("p").path
        let child = try tmp.directory("p/c").path
        let dead = tmp.url("dead").path
        let findings = [
            duplicate(.active, ".local/bin/claude", version: "1.0.0"),
            duplicate(.shadowed, "opt/homebrew/bin/claude", version: "2.0.0"),
        ]

        let result = scan([repeated, dead, parent, child, repeated, dead + "/"], duplicates: findings).findings

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
    }
}

/// A disk with nothing on it: every lookup finds nothing and nothing real is ever touched.
private struct NothingOnDiskFileSystem: CleanupFileSystem {
    func entry(at url: URL) throws -> CleanupEntry? { nil }
    func contents(of directory: URL) throws -> [CleanupEntry] { throw CleanupFileSystemError.notFound(directory.path) }
    func symlinkDestination(of url: URL) throws -> String { throw CleanupFileSystemError.notFound(url.path) }
    func realpath(_ url: URL) throws -> URL { throw CleanupFileSystemError.notFound(url.path) }
    func allocatedSize(of url: URL) throws -> Int64 { throw CleanupFileSystemError.notFound(url.path) }
    func readText(_ url: URL, maxBytes: Int) throws -> String { throw CleanupFileSystemError.notFound(url.path) }
    func createDirectory(_ url: URL) throws { throw CleanupFileSystemError.notFound(url.path) }
    func moveItem(_ source: URL, to destination: URL) throws { throw CleanupFileSystemError.notFound(source.path) }
    func trash(_ url: URL) throws { throw CleanupFileSystemError.notFound(url.path) }
}
