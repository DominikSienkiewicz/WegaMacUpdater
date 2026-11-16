import XCTest
@testable import MacUpdaterCore

/// Answers `brew uses --installed` from a script and records, for every call, which write
/// lease the coordinator held at that moment.
private final class ScriptedBrewQuery: CleanupBrewQuerying, @unchecked Sendable {
    private let result: Result<[String], Error>
    private let coordinator: OperationCoordinator?
    private let lock = NSLock()
    private var recorded: [String] = []
    private var recordedWrites: [String?] = []

    init(result: Result<[String], Error> = .success([]), coordinator: OperationCoordinator? = nil) {
        self.result = result
        self.coordinator = coordinator
    }

    var calls: [String] { lock.withLock { recorded } }
    var activeWrites: [String?] { lock.withLock { recordedWrites } }

    func usesInstalled(formula: String) async throws -> [String] {
        let activeWrite = await coordinator?.snapshot().activeWrite
        lock.withLock {
            recorded.append(formula)
            recordedWrites.append(activeWrite)
        }
        return try result.get()
    }
}

/// Records every uninstall (`cask:<token>` / `formula:<name>`) and the write lease held while it
/// ran; optionally fails after recording.
private final class RecordingBrewRemoval: CleanupBrewRemoving, @unchecked Sendable {
    private let failure: Error?
    private let coordinator: OperationCoordinator?
    private let lock = NSLock()
    private var recorded: [String] = []
    private var recordedWrites: [String?] = []

    init(failure: Error? = nil, coordinator: OperationCoordinator? = nil) {
        self.failure = failure
        self.coordinator = coordinator
    }

    var calls: [String] { lock.withLock { recorded } }
    var activeWrites: [String?] { lock.withLock { recordedWrites } }

    func uninstallCask(token: String) async throws {
        try await record("cask:\(token)")
    }

    func uninstallFormula(name: String) async throws {
        try await record("formula:\(name)")
    }

    private func record(_ call: String) async throws {
        let activeWrite = await coordinator?.snapshot().activeWrite
        lock.withLock {
            recorded.append(call)
            recordedWrites.append(activeWrite)
        }
        if let failure { throw failure }
    }
}

/// Delegates everything, but refuses to move one source path.
private struct FailingMoveFileSystem: CleanupFileSystem {
    let base: CleanupFileSystem
    let failingSource: String

    func entry(at url: URL) throws -> CleanupEntry? { try base.entry(at: url) }
    func contents(of directory: URL) throws -> [CleanupEntry] { try base.contents(of: directory) }
    func symlinkDestination(of url: URL) throws -> String { try base.symlinkDestination(of: url) }
    func realpath(_ url: URL) throws -> URL { try base.realpath(url) }
    func allocatedSize(of url: URL) throws -> Int64 { try base.allocatedSize(of: url) }
    func readText(_ url: URL, maxBytes: Int) throws -> String { try base.readText(url, maxBytes: maxBytes) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func trash(_ url: URL) throws { try base.trash(url) }

    func moveItem(_ source: URL, to destination: URL) throws {
        guard source.path != failingSource else { throw CleanupFileSystemError.io("\(source.path): refused") }
        try base.moveItem(source, to: destination)
    }
}

final class CleanupRemoverTests: XCTestCase {
    private static let stateDirectory = ".local/state/fnm_multishells"
    private static let staleNames = ["81234_1762761600000", "81235_1762761600001", "81236_1762761600002_x"]

    private var tmp: CleanupTempHome!
    private var trash: RecordingTrash!
    private var fileSystem: CleanupFileSystem!
    private var coordinator: OperationCoordinator!

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        let trash = RecordingTrash()
        self.trash = trash
        fileSystem = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(trash: { trash.record($0) }),
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
        coordinator = OperationCoordinator()
    }

    // MARK: - Brief cases

    func testCommandAndInstructionFindingsAreNeverExecuted() async throws {
        let file = try tmp.file("bin/tool", size: 16, executable: true)
        let recording = RecordingCleanupFileSystem(wrapping: fileSystem)
        let query = ScriptedBrewQuery()
        let removal = RecordingBrewRemoval()
        let remover = remover(brewQuery: query, brewRemoval: removal, fileSystem: recording)
        let actions: [CleanupAction] = [
            .command("npm uninstall -g tool"), .instruction(.removeWithCreatingTool),
            .instruction(.removeAppLinkWithAdminRights(link: file.path)), .none,
        ]

        for action in actions {
            let item = finding(path: file, source: .standalone, action: action, identity: try identity(of: file))
            let outcome = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))
            XCTAssertEqual(outcome, .notRemovable, "\(action)")
        }

        XCTAssertEqual(trash.urls, [])
        XCTAssertEqual(removal.calls, [])
        XCTAssertEqual(query.calls, [])
        XCTAssertEqual(recording.touched, [], "a command or instruction finding must not touch the disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testChangedFileIsNotTrashed() async throws {
        try installClaude(versions: ["2.1.318", "2.1.325"], current: "2.1.325")
        let old = tmp.url(".local/share/claude/versions/2.1.318")
        let scanned = try versionFinding(old)
        try FileManager.default.moveItem(at: old, to: tmp.url(".local/share/claude/2.1.318-aside"))
        try tmp.file(".local/share/claude/versions/2.1.318", size: 4096, executable: true)
        XCTAssertNotEqual(try identity(of: old), scanned.identity, "precondition: the file has a new inode")

        let outcome = await remover().execute(CleanupRemovalIntent(finding: scanned, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(trash.urls, [])
    }

    func testInUseNeedsAcknowledgementThenTrashes() async throws {
        try installClaude(versions: ["2.1.318", "2.1.325"], current: "2.1.325")
        let old = tmp.url(".local/share/claude/versions/2.1.318")
        let process = CleanupProcess(
            pid: 812, name: "claude", executablePath: old.path, arguments: [old.path, "--chrome-native-host"]
        )
        let remover = remover(processes: [process])
        let item = try versionFinding(old)

        let first = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(first, .needsInUseAcknowledgement([process]))
        XCTAssertEqual(trash.urls, [])

        let second = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(second, .removed)
        XCTAssertEqual(trash.urls, [old])
    }

    func testBatchMovesStaleEntriesIntoOneTrashedFolder() async throws {
        let (parent, entries) = try staleLinks()
        let item = try batchFinding(parent: parent, entries: entries)

        let outcome = await remover().execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .removed)
        let folder = tmp.url("\(Self.stateDirectory)/fnm_multishells-cleanup-2026-11-16")
        XCTAssertEqual(trash.urls.map(\.path), [folder.path])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), Self.staleNames)
        for name in Self.staleNames {
            XCTAssertEqual(try fileSystem.entry(at: folder.appending(component: name))?.kind, .symlink, name)
        }
        for entry in entries {
            XCTAssertNil(try fileSystem.entry(at: entry), "\(entry.lastPathComponent) is still beside the folder")
        }
    }

    func testFormulaGainingADependentIsNotUninstalled() async throws {
        let link = try brewLink("opt/homebrew/bin/python3.13", to: "opt/homebrew/Cellar/python@3.13/3.13.1/bin/python3.13")
        let query = ScriptedBrewQuery(result: .success(["mlx"]))
        let removal = RecordingBrewRemoval()
        let item = try brewFinding(link, .uninstallFormula("python@3.13"), source: .homebrewFormula(name: "python@3.13"))

        let outcome = await remover(brewQuery: query, brewRemoval: removal)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .nowRequiredBy(["mlx"]))
        XCTAssertEqual(query.calls, ["python@3.13"])
        XCTAssertEqual(removal.calls, [])
    }

    func testCaskRemovalCallsBrewWithTheExactToken() async throws {
        let link = try brewLink("opt/homebrew/bin/claude", to: "opt/homebrew/Caskroom/claude-code/2.1.311/claude")
        let query = ScriptedBrewQuery()
        let removal = RecordingBrewRemoval()
        let item = try brewFinding(link, .uninstallCask("claude-code"), source: .homebrewCask(token: "claude-code"))

        let outcome = await remover(brewQuery: query, brewRemoval: removal)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(removal.calls, ["cask:claude-code"])
        XCTAssertEqual(query.calls, [], "a cask has no formula dependents to look up")
    }

    // MARK: - Re-validation rulings

    func testVersionThePointerNowNamesIsNotTrashed() async throws {
        try installClaude(versions: ["2.1.318", "2.1.325"], current: "2.1.325")
        try tmp.file(".local/share/claude/versions/2.1.320/bin/claude", size: 4096, executable: true)
        let pointer = tmp.url(".local/bin/claude")
        let file = tmp.url(".local/share/claude/versions/2.1.318")
        let directory = tmp.url(".local/share/claude/versions/2.1.320")
        let scannedFile = try versionFinding(file)
        let scannedDirectory = try versionFinding(directory)

        try FileManager.default.removeItem(at: pointer)
        try tmp.symlink(".local/bin/claude", to: file.path)
        let pointedAtFile = await remover().execute(CleanupRemovalIntent(finding: scannedFile, inUseAcknowledged: true))

        try FileManager.default.removeItem(at: pointer)
        try tmp.symlink(".local/bin/claude", to: "../share/claude/versions/2.1.320/bin/claude")
        let pointedInsideDirectory = await remover()
            .execute(CleanupRemovalIntent(finding: scannedDirectory, inUseAcknowledged: true))

        XCTAssertEqual(pointedAtFile, .changedSinceScan)
        XCTAssertEqual(pointedInsideDirectory, .changedSinceScan)
        XCTAssertEqual(trash.urls, [])
    }

    func testRevalidationAndRemovalRunUnderTheWriteLease() async throws {
        let link = try brewLink("opt/homebrew/bin/python3.13", to: "opt/homebrew/Cellar/python@3.13/3.13.1/bin/python3.13")
        let query = ScriptedBrewQuery(coordinator: coordinator)
        let removal = RecordingBrewRemoval(coordinator: coordinator)
        let item = try brewFinding(link, .uninstallFormula("python@3.13"), source: .homebrewFormula(name: "python@3.13"))

        let outcome = await remover(brewQuery: query, brewRemoval: removal)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(query.activeWrites, ["cleanup.remove"], "the dependents re-check ran outside the write lease")
        XCTAssertEqual(removal.activeWrites, ["cleanup.remove"], "the uninstall ran outside the write lease")
        XCTAssertEqual(removal.calls, ["formula:python@3.13"])
        let afterwards = await coordinator.snapshot()
        XCTAssertNil(afterwards.activeWrite, "the write lease outlived the removal")
    }

    func testFailedDependentsLookupNeverUninstalls() async throws {
        let link = try brewLink("opt/homebrew/bin/python3.13", to: "opt/homebrew/Cellar/python@3.13/3.13.1/bin/python3.13")
        let query = ScriptedBrewQuery(result: .failure(BrewServiceError.brewNotFound))
        let removal = RecordingBrewRemoval()
        let item = try brewFinding(link, .uninstallFormula("python@3.13"), source: .homebrewFormula(name: "python@3.13"))

        let outcome = await remover(brewQuery: query, brewRemoval: removal)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .failed("BrewServiceError.brewNotFound"))
        XCTAssertEqual(removal.calls, [])
    }

    func testBrewFailureIsReportedWithoutItsOutput() async throws {
        let link = try brewLink("opt/homebrew/bin/claude", to: "opt/homebrew/Caskroom/claude-code/2.1.311/claude")
        let failure = BrewServiceError.commandFailed(
            arguments: ["uninstall", "--cask", "--", "claude-code"],
            result: ProcessResult(exitCode: 1, stdout: "HOMEBREW_GITHUB_API_TOKEN=ghp_secret", stderr: "Error: sudo password")
        )
        let removal = RecordingBrewRemoval(failure: failure)
        let item = try brewFinding(link, .uninstallCask("claude-code"), source: .homebrewCask(token: "claude-code"))

        let outcome = await remover(brewRemoval: removal).execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .failed("BrewServiceError.commandFailed"))
        XCTAssertEqual(removal.calls, ["cask:claude-code"])
    }

    func testBrewFindingWhoseLinkWasReplacedIsNotUninstalled() async throws {
        let link = try brewLink("opt/homebrew/bin/claude", to: "opt/homebrew/Caskroom/claude-code/2.1.311/claude")
        let item = try brewFinding(link, .uninstallCask("claude-code"), source: .homebrewCask(token: "claude-code"))
        try FileManager.default.moveItem(at: link, to: tmp.url("opt/homebrew/bin/claude-aside"))
        try tmp.symlink("opt/homebrew/bin/claude", to: tmp.url("opt/homebrew/Caskroom/claude-code/2.1.311/claude").path)
        let query = ScriptedBrewQuery()
        let removal = RecordingBrewRemoval()

        let outcome = await remover(brewQuery: query, brewRemoval: removal)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(removal.calls, [])
        XCTAssertEqual(query.calls, [])
    }

    func testBatchWithAVanishedEntryIsLeftAlone() async throws {
        let (parent, entries) = try staleLinks()
        let item = try batchFinding(parent: parent, entries: entries)
        try FileManager.default.removeItem(at: entries[1])

        let outcome = await remover().execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(trash.urls, [])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        XCTAssertEqual(remaining, [Self.staleNames[0], Self.staleNames[2]], "nothing may be staged or moved")
    }

    func testBatchEntryOutsideItsFolderIsNotRemovable() async throws {
        let (parent, entries) = try staleLinks()
        let stranger = try tmp.file("bin/tool", size: 16, executable: true)
        let item = try batchFinding(parent: parent, entries: [entries[0], stranger])

        let outcome = await remover().execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .notRemovable)
        XCTAssertEqual(trash.urls, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted(), Self.staleNames)
    }

    /// The scan pins one identity, so a Trash action naming several items could carry unchecked
    /// ones; the remover only accepts a single target.
    func testTrashOfSeveralItemsIsNotRemovable() async throws {
        let first = try tmp.file("bin/tool", size: 16, executable: true)
        let second = try tmp.file("bin2/tool", size: 16, executable: true)
        let item = finding(
            path: first, source: .standalone, action: .trash([first, second]), identity: try identity(of: first),
            detector: .pathDuplicates, status: .shadowed
        )

        let outcome = await remover().execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .notRemovable)
        XCTAssertEqual(trash.urls, [])
    }

    func testBatchFolderNameTakesTheNextFreeSuffix() async throws {
        let (parent, entries) = try staleLinks()
        try tmp.directory("\(Self.stateDirectory)/fnm_multishells-cleanup-2026-11-16")
        try tmp.directory("\(Self.stateDirectory)/fnm_multishells-cleanup-2026-11-16-2")
        let item = try batchFinding(parent: parent, entries: entries)

        let outcome = await remover().execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .removed)
        let folder = tmp.url("\(Self.stateDirectory)/fnm_multishells-cleanup-2026-11-16-3")
        XCTAssertEqual(trash.urls.map(\.path), [folder.path])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), Self.staleNames)
    }

    func testFailedMoveStopsTheBatchAndTrashesNothing() async throws {
        let (parent, entries) = try staleLinks()
        let item = try batchFinding(parent: parent, entries: entries)
        let failing = FailingMoveFileSystem(base: fileSystem, failingSource: entries[1].path)

        let outcome = await remover(fileSystem: failing).execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .failed("CleanupFileSystemError.io"))
        XCTAssertEqual(trash.urls, [])
        let folder = tmp.url("\(Self.stateDirectory)/fnm_multishells-cleanup-2026-11-16")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [Self.staleNames[0]])
        XCTAssertNotNil(try fileSystem.entry(at: entries[1]))
        XCTAssertNotNil(try fileSystem.entry(at: entries[2]), "the batch went on after a failed move")
    }

    /// Trashing an fnm link never touches what it points to (spec D8), so a running `node` from the
    /// linked installation does not make the batch "in use"; a process naming the link itself does.
    func testBatchInUseCheckLooksAtTheLinksNotTheirTarget() async throws {
        let (parent, entries) = try staleLinks()
        let item = try batchFinding(parent: parent, entries: entries)
        let installation = tmp.url(".local/share/fnm/node-versions/v22.11.0/installation")
        let node = CleanupProcess(
            pid: 900, name: "node", executablePath: installation.appending(path: "bin/node").path, arguments: ["node"]
        )
        let shell = CleanupProcess(
            pid: 901, name: "zsh", executablePath: "/bin/zsh", arguments: ["zsh", entries[0].appending(path: "bin").path]
        )

        let namingTheLink = await remover(processes: [node, shell])
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))
        XCTAssertEqual(namingTheLink, .needsInUseAcknowledgement([shell]))
        XCTAssertEqual(trash.urls, [])

        let runningTheTarget = await remover(processes: [node])
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))
        XCTAssertEqual(runningTheTarget, .removed)
        XCTAssertEqual(trash.urls.count, 1)
    }

    // MARK: - Helpers

    private func remover(
        processes: [CleanupProcess] = [],
        brewQuery: CleanupBrewQuerying = ScriptedBrewQuery(),
        brewRemoval: CleanupBrewRemoving = RecordingBrewRemoval(),
        fileSystem: CleanupFileSystem? = nil
    ) -> CleanupRemover {
        CleanupRemover(
            fileSystem: fileSystem ?? self.fileSystem,
            inspector: FakeProcessInspector(processes: processes, bootTime: Date(timeIntervalSince1970: 0)),
            brewQuery: brewQuery, brewRemoval: brewRemoval, coordinator: coordinator, home: tmp.home,
            today: { Self.november16Noon }
        )
    }

    private static let november16Noon: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12)) ?? .distantPast
    }()

    private func identity(of url: URL) throws -> CleanupFileIdentity {
        try XCTUnwrap(fileSystem.entry(at: url), "nothing at \(url.path)").identity
    }

    private func installClaude(versions: [String], current: String) throws {
        for version in versions {
            try tmp.file(".local/share/claude/versions/\(version)", size: 4096, executable: true)
        }
        try tmp.symlink(".local/bin/claude", to: tmp.url(".local/share/claude/versions/\(current)").path)
    }

    private func finding(
        path: URL, source: CleanupSource?, action: CleanupAction, identity: CleanupFileIdentity?,
        detector: CleanupDetectorID = .versionDirectories, status: CleanupStatus = .unused
    ) -> CleanupFinding {
        CleanupFinding(
            detector: detector, tool: path.lastPathComponent, path: path, realpath: nil, source: source,
            version: nil, size: nil, status: status, reason: .unknownVersionDirectory, action: action,
            risk: .low, bucket: .safe, identity: identity
        )
    }

    /// A D3 finding for an old Claude Code version, identified as the scan saw it.
    private func versionFinding(_ url: URL) throws -> CleanupFinding {
        finding(
            path: url, source: .nativeVersionDirectory(tool: "claude"), action: .trash([url]),
            identity: try identity(of: url)
        )
    }

    /// A link at `path` to an executable at `target`, both relative to the home.
    private func brewLink(_ path: String, to target: String) throws -> URL {
        let real = try tmp.file(target, size: 64, executable: true)
        return try tmp.symlink(path, to: real.path)
    }

    private func brewFinding(_ link: URL, _ action: CleanupBrewAction, source: CleanupSource) throws -> CleanupFinding {
        finding(
            path: link, source: source, action: .brew(action), identity: try identity(of: link),
            detector: .pathDuplicates, status: .shadowed
        )
    }

    /// Three fnm per-shell links into one node installation, as `fnm env` leaves them.
    private func staleLinks() throws -> (parent: URL, entries: [URL]) {
        let installation = try tmp.directory(".local/share/fnm/node-versions/v22.11.0/installation")
        try tmp.file(".local/share/fnm/node-versions/v22.11.0/installation/bin/node", size: 64, executable: true)
        let entries = try Self.staleNames.map { name in
            try tmp.symlink("\(Self.stateDirectory)/\(name)", to: installation.path)
        }
        return (tmp.url(Self.stateDirectory), entries)
    }

    private func batchFinding(parent: URL, entries: [URL]) throws -> CleanupFinding {
        finding(
            path: parent, source: nil, action: .trashBatch(parent: parent, entries: entries),
            identity: try identity(of: parent), detector: .shellState, status: .stale
        )
    }
}
