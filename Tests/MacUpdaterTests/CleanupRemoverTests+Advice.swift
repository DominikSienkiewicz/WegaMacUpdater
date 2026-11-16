import XCTest
@testable import MacUpdaterCore

/// Records every Homebrew call, so a test can show that none was made.
private final class RecordingBrewCalls: CleanupBrewQuerying, CleanupBrewRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var calls: [String] { lock.withLock { recorded } }

    func usesInstalled(formula: String) async throws -> [String] {
        record("uses \(formula)")
        return []
    }

    func cleanupDryRun(package: String?) async throws -> [CleanupBrewCleanupItem] {
        record("cleanup --dry-run \(package ?? "")")
        return []
    }

    func autoremoveDryRun() async throws -> [String] {
        record("autoremove --dry-run")
        return []
    }

    func uninstallCask(token: String) async throws { record("uninstall --cask \(token)") }
    func uninstallFormula(name: String) async throws { record("uninstall \(name)") }
    func cleanupPackage(name: String) async throws { record("cleanup \(name)") }

    private func record(_ call: String) {
        lock.withLock { recorded.append(call) }
    }
}

// MARK: - D9 and D10 only advise (kept out of CleanupRemoverTests.swift for SwiftLint file_length)

extension CleanupRemoverTests {
    /// Whatever a D9 or D10 finding suggests (edit a shell file, run `tccutil`, switch an entry off,
    /// nothing), the remover refuses it and touches neither the disk nor Homebrew.
    func testHygieneAndMapFindingsAreNeverRemovable() async throws {
        let home = try CleanupTempHome()
        let trash = RecordingTrash()
        let guarded = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(trash: { trash.record($0) }),
            guard: ProtectedLocationGuard(home: home.home, mounts: FixedMountTable(["/"]))
        )
        let recording = RecordingCleanupFileSystem(wrapping: guarded)
        let brew = RecordingBrewCalls()
        let remover = CleanupRemover(
            fileSystem: recording, inspector: FakeProcessInspector(processes: [], bootTime: Date(timeIntervalSince1970: 0)),
            brewQuery: brew, brewRemoval: brew, coordinator: OperationCoordinator(), home: home.home,
            today: { Date(timeIntervalSince1970: 0) }
        )
        let client = try home.file("bin/tool", size: 16, executable: true)
        let clientIdentity = try XCTUnwrap(guarded.entry(at: client)).identity
        let entry = home.url("gone/bin")
        let grants = [CleanupTCCGrant(service: .documents, allowed: true)]
        let copy = CleanupTCCLink(findingID: "D1:shadowed:\(client.path)", kind: .copyToRemove)
        let advice = [
            adviceFinding(
                .pathHygiene, entry, status: .deadEntry, reason: .missingPathEntry,
                action: .instruction(.editShellFiles(
                    entry: entry.path, locations: [CleanupShellFileLocation(file: home.url(".zshrc").path, line: 3)]
                ))
            ),
            adviceFinding(
                .tccMap, home.url("Library/Application Support/com.apple.TCC/TCC.db"), status: .info,
                reason: .tccEntry(grants: grants, link: nil),
                action: .command("tccutil reset SystemPolicyDocumentsFolder com.example.editor")
            ),
            adviceFinding(
                .tccMap, client, status: .info, reason: .tccEntry(grants: grants, link: copy),
                action: .instruction(.switchOffInFilesAndFolders), identity: clientIdentity
            ),
            adviceFinding(
                .tccMap, client, status: .info, reason: .tccEntry(grants: grants, link: nil), action: .none,
                identity: clientIdentity
            ),
        ]

        for finding in advice {
            let outcome = await remover.execute(CleanupRemovalIntent(finding: finding, inUseAcknowledged: true))
            XCTAssertEqual(outcome, .notRemovable, "\(finding.detector.rawValue) \(finding.action)")
        }

        XCTAssertEqual(trash.urls, [])
        XCTAssertEqual(brew.calls, [])
        XCTAssertEqual(recording.touched, [], "an advice-only finding must not touch the disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: client.path))
    }

    private func adviceFinding(
        _ detector: CleanupDetectorID, _ path: URL, status: CleanupStatus, reason: CleanupReason,
        action: CleanupAction, identity: CleanupFileIdentity? = nil
    ) -> CleanupFinding {
        CleanupFinding(
            detector: detector, tool: path.lastPathComponent, path: path, realpath: nil, source: nil, version: nil,
            size: nil, status: status, reason: reason, action: action, risk: .low, bucket: .excluded, identity: identity
        )
    }
}
