import XCTest
@testable import MacUpdaterCore

/// Serves fixed rows, or throws a fixed error, and records every call.
final class FakeTCCDatabase: CleanupTCCDatabaseReading, @unchecked Sendable {
    let fileURL: URL
    private let result: Result<[CleanupTCCRow], Error>
    private let lock = NSLock()
    private var requests: [[CleanupTCCService]] = []

    init(fileURL: URL, rows: [CleanupTCCRow]) {
        self.fileURL = fileURL
        result = .success(rows)
    }

    init(fileURL: URL, error: Error) {
        self.fileURL = fileURL
        result = .failure(error)
    }

    var calls: Int {
        lock.withLock { requests.count }
    }

    var requestedServices: [[CleanupTCCService]] {
        lock.withLock { requests }
    }

    func rows(for services: [CleanupTCCService]) throws -> [CleanupTCCRow] {
        lock.withLock { requests.append(services) }
        return try result.get()
    }
}

private struct UnrelatedError: Error {}

final class CleanupTCCMapDetectorTests: XCTestCase {
    private static let pathClient = 1
    private static let bundleClient = 0
    private static let allowed = 2
    private static let denied = 0

    private var tmp: CleanupTempHome!
    private var recording: RecordingCleanupFileSystem!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        tmp = try CleanupTempHome()
        recording = RecordingCleanupFileSystem(wrapping: LiveCleanupFileSystem(trash: { _ in }))
        databaseURL = tmp.url("Library/Application Support/com.apple.TCC/TCC.db")
    }

    private var guarded: CleanupFileSystem {
        GuardedCleanupFileSystem(
            base: recording,
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
    }

    private func scan(
        _ rows: [CleanupTCCRow], linkingTo findings: [CleanupFinding] = []
    ) throws -> (findings: [CleanupFinding], notes: [CleanupDetectorNote]) {
        let database = FakeTCCDatabase(fileURL: databaseURL, rows: rows)
        return try CleanupTCCMapDetector(database: database, fileSystem: guarded).scan(linkingTo: findings)
    }

    private func row(
        _ service: CleanupTCCService, _ client: String,
        type: Int = CleanupTCCMapDetectorTests.pathClient, auth: Int = CleanupTCCMapDetectorTests.allowed
    ) -> CleanupTCCRow {
        CleanupTCCRow(service: service.rawValue, client: client, clientType: type, authValue: auth)
    }

    private func copy(
        _ detector: CleanupDetectorID, _ status: CleanupStatus, _ path: URL, realpath: URL? = nil,
        source: CleanupSource? = .standalone
    ) -> CleanupFinding {
        CleanupFinding(
            detector: detector, tool: "claude", path: path, realpath: realpath ?? path, source: source,
            version: nil, size: 10, status: status, reason: .currentVersion, action: .none, risk: .low,
            bucket: .needsDecision, identity: nil
        )
    }

    private func identity(of url: URL) throws -> CleanupFileIdentity? {
        try LiveCleanupFileSystem(trash: { _ in }).entry(at: url)?.identity
    }

    private func assertMapShape(_ finding: CleanupFinding, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(finding.detector, .tccMap, file: file, line: line)
        XCTAssertNil(finding.size, file: file, line: line)
        XCTAssertNil(finding.version, file: file, line: line)
        XCTAssertEqual(finding.risk, .low, file: file, line: line)
        XCTAssertEqual(finding.bucket, .excluded, file: file, line: line)
    }

    func testPathClientForAShadowedCopyIsMarkedForRemoval() throws {
        let client = try tmp.file(".npm-global/bin/claude", size: 4, executable: true)
        let shadowed = copy(.pathDuplicates, .shadowed, client)

        let result = try scan(
            [row(.downloads, client.path, auth: Self.denied), row(.documents, client.path)],
            linkingTo: [shadowed]
        )

        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.findings.count, 1)
        let finding = result.findings[0]
        assertMapShape(finding)
        XCTAssertEqual(finding.status, .info)
        XCTAssertEqual(finding.reason, .tccEntry(
            grants: [
                CleanupTCCGrant(service: .documents, allowed: true),
                CleanupTCCGrant(service: .downloads, allowed: false),
            ],
            link: CleanupTCCLink(findingID: shadowed.id, kind: .copyToRemove)
        ))
        XCTAssertEqual(finding.action, .instruction(.switchOffInFilesAndFolders))
        XCTAssertEqual(finding.tool, "claude")
        XCTAssertEqual(finding.path.path, client.path)
        XCTAssertEqual(finding.realpath?.path, client.path)
        XCTAssertNil(finding.source)
        XCTAssertEqual(finding.identity, try identity(of: client))
    }

    func testPathClientForTheActiveCopyHasNoAdvice() throws {
        let version = try tmp.file(".local/share/claude/versions/2.1.330", size: 4, executable: true)
        let pointer = try tmp.symlink(".local/bin/claude", to: version.path)
        let active = copy(.pathDuplicates, .active, pointer, realpath: version)

        let finding = try XCTUnwrap(try scan([row(.documents, version.path)], linkingTo: [active]).findings.first)

        XCTAssertEqual(finding.status, .info)
        XCTAssertEqual(finding.reason, .tccEntry(
            grants: [CleanupTCCGrant(service: .documents, allowed: true)],
            link: CleanupTCCLink(findingID: active.id, kind: .activeCopy)
        ))
        XCTAssertEqual(finding.action, .none)
        XCTAssertEqual(finding.tool, "2.1.330")
    }

    func testPathClientThroughALinkMatchesByItsRealpath() throws {
        let version = try tmp.file(".local/share/claude/versions/2.1.330", size: 4, executable: true)
        let pointer = try tmp.symlink(".local/bin/claude", to: version.path)
        let shadowed = copy(.pathDuplicates, .shadowed, tmp.url("elsewhere/claude"), realpath: version)

        let finding = try XCTUnwrap(try scan([row(.desktop, pointer.path)], linkingTo: [shadowed]).findings.first)

        XCTAssertEqual(finding.realpath?.path, version.path)
        XCTAssertEqual(finding.reason, .tccEntry(
            grants: [CleanupTCCGrant(service: .desktop, allowed: true)],
            link: CleanupTCCLink(findingID: shadowed.id, kind: .copyToRemove)
        ))
        XCTAssertEqual(finding.identity, try identity(of: pointer))
    }

    func testPathClientInsideAVersionDirectoryLinksToD3() throws {
        let version = try tmp.file(".local/share/claude/versions/2.1.322", size: 4, executable: true)
        let unused = copy(.versionDirectories, .unused, version, source: .nativeVersionDirectory(tool: "claude"))

        let finding = try XCTUnwrap(try scan([row(.documents, version.path)], linkingTo: [unused]).findings.first)

        XCTAssertEqual(finding.reason, .tccEntry(
            grants: [CleanupTCCGrant(service: .documents, allowed: true)],
            link: CleanupTCCLink(findingID: unused.id, kind: .copyToRemove)
        ))
        XCTAssertEqual(finding.action, .instruction(.switchOffInFilesAndFolders))
    }

    func testPathClientInsideAnAppManagedLocation() throws {
        let location = try tmp.directory("Library/Application Support/Claude/claude-code")
        let client = try tmp.file("Library/Application Support/Claude/claude-code/2.1.300/claude", size: 4, executable: true)
        let managed = copy(.versionDirectories, .appManaged, location, source: .appManaged(owner: "Claude"))

        let finding = try XCTUnwrap(try scan([row(.downloads, client.path)], linkingTo: [managed]).findings.first)

        XCTAssertEqual(finding.reason, .tccEntry(
            grants: [CleanupTCCGrant(service: .downloads, allowed: true)],
            link: CleanupTCCLink(findingID: managed.id, kind: .appManaged(owner: "Claude"))
        ))
        XCTAssertEqual(finding.action, .none)
        XCTAssertEqual(finding.tool, "claude")
    }

    func testUnlinkedExistingClientHasNoLink() throws {
        let client = try tmp.file("tools/foo", size: 4, executable: true)
        let unrelated = [
            copy(.pathDuplicates, .shadowed, tmp.url("tools")),
            copy(.versionDirectories, .unused, tmp.url("tool")),
            copy(.versionDirectories, .unused, tmp.url("tools/fo")),
            copy(.homebrew, .unused, tmp.url("tools")),
        ]

        let finding = try XCTUnwrap(try scan([row(.documents, client.path)], linkingTo: unrelated).findings.first)

        assertMapShape(finding)
        XCTAssertEqual(finding.status, .info)
        XCTAssertEqual(finding.reason, .tccEntry(grants: [CleanupTCCGrant(service: .documents, allowed: true)], link: nil))
        XCTAssertEqual(finding.action, .none)
    }

    func testGoneFileIsADeadEntry() throws {
        let client = tmp.url("gone/claude")

        let result = try scan([row(.documents, client.path), row(.desktop, client.path, auth: Self.denied)])

        XCTAssertEqual(result.findings.count, 1)
        let finding = result.findings[0]
        assertMapShape(finding)
        XCTAssertEqual(finding.status, .deadEntry)
        XCTAssertEqual(finding.reason, .tccEntryFileGone(grants: [
            CleanupTCCGrant(service: .desktop, allowed: false),
            CleanupTCCGrant(service: .documents, allowed: true),
        ]))
        XCTAssertEqual(finding.action, .instruction(.switchOffInFilesAndFolders))
        XCTAssertEqual(finding.tool, "claude")
        XCTAssertEqual(finding.path.path, client.path)
        XCTAssertNil(finding.realpath)
        XCTAssertNil(finding.identity)
    }

    func testClientInDownloadsIsSkippedUntouched() throws {
        let client = try tmp.file("Downloads/claude", size: 4, executable: true)
        let downloads = CleanupPathText.components(of: tmp.url("Downloads").path)

        let result = try scan([row(.documents, client.path)])

        XCTAssertEqual(result.findings.count, 1)
        let finding = result.findings[0]
        assertMapShape(finding)
        XCTAssertEqual(finding.status, .skippedProtected)
        XCTAssertEqual(finding.reason, .protectedLocation)
        XCTAssertEqual(finding.action, .none)
        XCTAssertEqual(finding.tool, "claude")
        XCTAssertEqual(finding.path.path, client.path)
        XCTAssertNil(finding.realpath)
        XCTAssertNil(finding.identity)
        let touchedDownloads = recording.touched.filter { CleanupPathText.components(of: $0).starts(with: downloads) }
        XCTAssertEqual(touchedDownloads, [])
    }

    func testUnusablePathClientsAreSkipped() throws {
        let rows = ["relative/bin", "~/bin", "", "/a\u{0}b"].map { row(.documents, $0) }
            + [row(.documents, tmp.url("bin/tool").path, type: 2)]

        let result = try scan(rows)

        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.notes, [CleanupDetectorNote(detector: .tccMap, kind: .tccMapEmpty)])
        XCTAssertEqual(recording.touched, [])
    }

    func testBundleClientGetsOneResetPerService() throws {
        let bundle = "com.googlecode.iterm2"
        let rows = [
            row(.downloads, bundle, type: Self.bundleClient, auth: Self.denied),
            row(.documents, bundle, type: Self.bundleClient),
        ]

        let result = try scan(rows)

        XCTAssertEqual(result.findings.count, 1)
        let finding = result.findings[0]
        assertMapShape(finding)
        XCTAssertEqual(finding.status, .info)
        XCTAssertEqual(finding.tool, bundle)
        XCTAssertEqual(finding.path, databaseURL)
        XCTAssertEqual(finding.source, .appBundle(name: bundle))
        XCTAssertEqual(finding.reason, .tccEntry(
            grants: [
                CleanupTCCGrant(service: .documents, allowed: true),
                CleanupTCCGrant(service: .downloads, allowed: false),
            ],
            link: nil
        ))
        XCTAssertEqual(finding.action, .command(
            "tccutil reset SystemPolicyDocumentsFolder com.googlecode.iterm2; tccutil reset SystemPolicyDownloadsFolder com.googlecode.iterm2"
        ))
        let commands = result.findings.compactMap { finding -> String? in
            if case .command(let text) = finding.action { text } else { nil }
        }
        XCTAssertFalse(commands.contains { $0.contains("reset All") })
        XCTAssertEqual(recording.touched, [])
    }

    func testUnsafeBundleIdGetsNoCommand() throws {
        let unsafe = ["com.evil; rm -rf ~", "", "com.example_app", "com.przykład.app", "com.evil\nrm"]

        let result = try scan(unsafe.map { row(.documents, $0, type: Self.bundleClient) })

        XCTAssertEqual(result.findings.map(\.tool), unsafe)
        XCTAssertEqual(result.findings.map(\.action), Array(repeating: CleanupAction.none, count: unsafe.count))
        XCTAssertEqual(result.findings.map(\.status), Array(repeating: CleanupStatus.info, count: unsafe.count))
    }

    func testLimitedCountsAsAllowed() throws {
        let rows = [
            row(.documents, "com.example.limited", type: Self.bundleClient, auth: 3),
            row(.documents, "com.example.unknown", type: Self.bundleClient, auth: 1),
        ]

        let reasons = try scan(rows).findings.map(\.reason)

        XCTAssertEqual(reasons, [
            .tccEntry(grants: [CleanupTCCGrant(service: .documents, allowed: true)], link: nil),
            .tccEntry(grants: [CleanupTCCGrant(service: .documents, allowed: false)], link: nil),
        ])
    }

    func testDatabaseErrorsBecomeNotes() throws {
        let cases: [(CleanupTCCDatabaseError, CleanupDetectorNote.Kind)] = [
            (.unreadable, .tccUnreadable),
            (.unsupportedSchema, .tccUnsupportedSchema),
        ]
        for (error, kind) in cases {
            let database = FakeTCCDatabase(fileURL: databaseURL, error: error)

            let result = try CleanupTCCMapDetector(database: database, fileSystem: guarded).scan(linkingTo: [])

            XCTAssertEqual(result.findings, [])
            XCTAssertEqual(result.notes, [CleanupDetectorNote(detector: .tccMap, kind: kind)])
            XCTAssertEqual(database.requestedServices, [CleanupTCCService.allCases])
        }

        let empty = FakeTCCDatabase(fileURL: databaseURL, rows: [])
        let emptyResult = try CleanupTCCMapDetector(database: empty, fileSystem: guarded).scan(linkingTo: [])
        XCTAssertEqual(emptyResult.findings, [])
        XCTAssertEqual(emptyResult.notes, [CleanupDetectorNote(detector: .tccMap, kind: .tccMapEmpty)])
        XCTAssertEqual(empty.calls, 1)

        let failing = FakeTCCDatabase(fileURL: databaseURL, error: UnrelatedError())
        XCTAssertThrowsError(try CleanupTCCMapDetector(database: failing, fileSystem: guarded).scan(linkingTo: [])) {
            XCTAssertTrue($0 is UnrelatedError)
        }
        XCTAssertEqual(recording.touched, [])
    }

    func testIdsAreUniqueAcrossBundleClients() throws {
        let rows = ["com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable"]
            .map { row(.documents, $0, type: Self.bundleClient) }

        let ids = try scan(rows).findings.map(\.id)

        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3)
    }

    func testTwoSpellingsOfOnePathClientKeepTheFirstFinding() throws {
        let client = try tmp.file("tools/foo", size: 4, executable: true)

        let findings = try scan([row(.documents, client.path), row(.desktop, client.path + "/")]).findings

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.map(\.reason), [
            .tccEntry(grants: [CleanupTCCGrant(service: .documents, allowed: true)], link: nil),
        ])
    }
}
