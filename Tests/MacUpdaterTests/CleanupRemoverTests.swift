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

    func cleanupDryRun(package: String?) async throws -> [CleanupBrewCleanupItem] { [] }
    func autoremoveDryRun() async throws -> [String] { [] }
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

    func cleanupPackage(name: String) async throws {
        try await record("cleanup:\(name)")
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

/// Answers `brew cleanup --dry-run -- <name>` with fixed items and records every query
/// (`cleanup:<name>`, `uses:<name>`, `autoremove`) with the write lease held while it ran.
private final class ScriptedCleanupDryRun: CleanupBrewQuerying, @unchecked Sendable {
    private let items: [CleanupBrewCleanupItem]
    private let coordinator: OperationCoordinator?
    private let lock = NSLock()
    private var recorded: [String] = []
    private var recordedWrites: [String?] = []

    init(items: [CleanupBrewCleanupItem], coordinator: OperationCoordinator? = nil) {
        self.items = items
        self.coordinator = coordinator
    }

    var calls: [String] { lock.withLock { recorded } }
    var activeWrites: [String?] { lock.withLock { recordedWrites } }

    func usesInstalled(formula: String) async throws -> [String] {
        await record("uses:\(formula)")
        return []
    }

    func cleanupDryRun(package: String?) async throws -> [CleanupBrewCleanupItem] {
        await record(package.map { "cleanup:\($0)" } ?? "cleanup")
        return items
    }

    func autoremoveDryRun() async throws -> [String] {
        await record("autoremove")
        return []
    }

    private func record(_ call: String) async {
        let activeWrite = await coordinator?.snapshot().activeWrite
        lock.withLock {
            recorded.append(call)
            recordedWrites.append(activeWrite)
        }
    }
}

/// Gives every re-check one fixed answer and records the findings it was asked about.
private final class FixedReferenceRecheck: CleanupReferenceRechecking, @unchecked Sendable {
    private let stillUnreferenced: Bool
    private let lock = NSLock()
    private var recorded: [CleanupFinding] = []

    init(stillUnreferenced: Bool) {
        self.stillUnreferenced = stillUnreferenced
    }

    var asked: [CleanupFinding] { lock.withLock { recorded } }

    func isStillUnreferenced(_ finding: CleanupFinding) async throws -> Bool {
        lock.withLock { recorded.append(finding) }
        return stillUnreferenced
    }
}

/// A Homebrew link to one version and, installed after the scan, a newer version of the same package.
private struct PackageUpgrade {
    let action: CleanupBrewAction
    let source: CleanupSource
    let link: String
    let target: String
    let newer: String
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

    /// A persisted report keeps its buttons. Once the copy that shadowed this one is gone, this
    /// one may be the only working copy left, so it is not removed.
    func testShadowedCopyWhoseActiveCopyIsGoneIsNotRemoved() async throws {
        let active = try tmp.file(".local/bin/gh", size: 16, executable: true)
        let link = try brewLink("opt/homebrew/bin/gh", to: "opt/homebrew/Cellar/gh/2.104.0/bin/gh")
        let standalone = try tmp.file("bin2/gh", size: 16, executable: true)
        let brewItem = try shadowedFinding(
            link, action: .brew(.uninstallFormula("gh")), source: .homebrewFormula(name: "gh"), shadowedBy: active
        )
        let trashItem = try shadowedFinding(standalone, action: .trash([standalone]), source: .standalone, shadowedBy: active)
        let whileShadowed = await remover().execute(CleanupRemovalIntent(finding: brewItem, inUseAcknowledged: false))
        XCTAssertEqual(whileShadowed, .removed, "precondition: a copy that is still shadowed may go")

        try FileManager.default.removeItem(at: active)
        let query = ScriptedBrewQuery()
        let removal = RecordingBrewRemoval()
        let remover = remover(brewQuery: query, brewRemoval: removal)
        let brewOutcome = await remover.execute(CleanupRemovalIntent(finding: brewItem, inUseAcknowledged: true))
        let trashOutcome = await remover.execute(CleanupRemovalIntent(finding: trashItem, inUseAcknowledged: true))

        XCTAssertEqual(brewOutcome, .changedSinceScan)
        XCTAssertEqual(trashOutcome, .changedSinceScan)
        XCTAssertEqual(removal.calls, [])
        XCTAssertEqual(query.calls, [], "no brew call once the active copy is gone")
        XCTAssertEqual(trash.urls, [])
    }

    /// `brew uninstall` removes every version of the package, so when the active copy now resolves
    /// into the same `Cellar/<name>` or `Caskroom/<token>` the shadowed copy came from, nothing runs.
    func testBrewFindingWhoseActiveCopyNowComesFromTheSamePackageIsNotUninstalled() async throws {
        let upgrades = [
            PackageUpgrade(
                action: .uninstallFormula("gh"), source: .homebrewFormula(name: "gh"), link: "opt/homebrew/bin/gh",
                target: "opt/homebrew/Cellar/gh/2.104.0/bin/gh", newer: "opt/homebrew/Cellar/gh/2.105.0/bin/gh"
            ),
            PackageUpgrade(
                action: .uninstallCask("claude-code"), source: .homebrewCask(token: "claude-code"),
                link: "opt/homebrew/bin/claude", target: "opt/homebrew/Caskroom/claude-code/2.1.311/claude",
                newer: "opt/homebrew/Caskroom/claude-code/2.1.325/claude"
            ),
        ]
        for (offset, upgrade) in upgrades.enumerated() {
            let active = try tmp.file(".local/bin/tool\(offset)", size: 16, executable: true)
            let link = try brewLink(upgrade.link, to: upgrade.target)
            let finding = try shadowedFinding(link, action: .brew(upgrade.action), source: upgrade.source, shadowedBy: active)
            let newer = try tmp.file(upgrade.newer, size: 16, executable: true)
            try FileManager.default.removeItem(at: active)
            try tmp.symlink(".local/bin/tool\(offset)", to: newer.path)
            let query = ScriptedBrewQuery()
            let removal = RecordingBrewRemoval()

            let outcome = await remover(brewQuery: query, brewRemoval: removal)
                .execute(CleanupRemovalIntent(finding: finding, inUseAcknowledged: true))

            XCTAssertEqual(outcome, .changedSinceScan, "\(upgrade.action)")
            XCTAssertEqual(removal.calls, [], "\(upgrade.action)")
            XCTAssertEqual(query.calls, [], "\(upgrade.action)")
        }
    }

    func testBrewFindingWhoseTargetLeftItsPackageIsNotUninstalled() async throws {
        let active = try tmp.file(".local/bin/gh", size: 16, executable: true)
        let link = try brewLink("opt/homebrew/bin/gh", to: "opt/homebrew/opt-elsewhere/gh/bin/gh")
        let finding = try shadowedFinding(
            link, action: .brew(.uninstallFormula("gh")), source: .homebrewFormula(name: "gh"), shadowedBy: active
        )
        let removal = RecordingBrewRemoval()

        let outcome = await remover(brewRemoval: removal).execute(CleanupRemovalIntent(finding: finding, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(removal.calls, [])
    }

    func testShadowedCopyTheActiveCopyNowResolvesToIsNotRemoved() async throws {
        let standalone = try tmp.file("bin2/tool", size: 16, executable: true)
        let active = try tmp.file(".local/bin/tool", size: 16, executable: true)
        let item = try shadowedFinding(standalone, action: .trash([standalone]), source: .standalone, shadowedBy: active)
        try FileManager.default.removeItem(at: active)
        try tmp.symlink(".local/bin/tool", to: standalone.path)

        let outcome = await remover().execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(trash.urls, [])
    }

    func testShadowedCopyWhoseActiveCopyIsNoLongerExecutableIsNotRemoved() async throws {
        let standalone = try tmp.file("bin2/tool", size: 16, executable: true)
        let active = try tmp.file(".local/bin/tool", size: 16, executable: true)
        let item = try shadowedFinding(standalone, action: .trash([standalone]), source: .standalone, shadowedBy: active)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: active.path)

        let outcome = await remover().execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(trash.urls, [])
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

    /// A D1 finding for a copy the scan saw shadowed by `active`, identified as the scan saw it.
    private func shadowedFinding(
        _ path: URL, action: CleanupAction, source: CleanupSource, shadowedBy active: URL
    ) throws -> CleanupFinding {
        CleanupFinding(
            detector: .pathDuplicates, tool: path.lastPathComponent, path: path, realpath: nil, source: source,
            version: nil, size: nil, status: .shadowed, reason: .shadowedBy(path: active.path), action: action,
            risk: .low, bucket: .safe, identity: try identity(of: path)
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

// MARK: - brew cleanup per package and the reference re-check

extension CleanupRemoverTests {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let oldNodeKeg = "opt/homebrew/Cellar/node/22.1.0"
    private static let currentNodeKeg = "opt/homebrew/Cellar/node/23.0.0"

    func testBrewCleanupRunsPerPackageAfterAFreshDryRun() async throws {
        let package = try nodeKegs(newestAge: 20 * Self.day)
        let query = ScriptedCleanupDryRun(items: [dryRunItem(Self.oldNodeKeg)], coordinator: coordinator)
        let removal = RecordingBrewRemoval(coordinator: coordinator)
        let item = try cleanupFinding(package, name: "node", source: .homebrewFormula(name: "node"))

        let outcome = await remover(brewQuery: query, brewRemoval: removal)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(query.calls, ["cleanup:node"], "the dry run must name the package, never run globally")
        XCTAssertEqual(removal.calls, ["cleanup:node"])
        XCTAssertEqual(query.activeWrites, ["cleanup.remove"], "the dry run ran outside the write lease")
        XCTAssertEqual(removal.activeWrites, ["cleanup.remove"], "brew cleanup ran outside the write lease")
    }

    func testBrewCleanupWithNothingLeftAsksForARescan() async throws {
        let package = try nodeKegs(newestAge: 20 * Self.day)
        let query = ScriptedCleanupDryRun(items: [])
        let removal = RecordingBrewRemoval()
        let item = try cleanupFinding(package, name: "node", source: .homebrewFormula(name: "node"))

        let outcome = await remover(brewQuery: query, brewRemoval: removal)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(query.calls, ["cleanup:node"])
        XCTAssertEqual(removal.calls, [])
    }

    /// A package upgraded within the retention window keeps its old versions, so the upgrade can
    /// still be undone; the newest version directory's date decides, for a formula and a cask alike.
    func testBrewCleanupRefusedAfterARecentUpgrade() async throws {
        let formula = try nodeKegs(newestAge: Self.day)
        try keg("opt/homebrew/Caskroom/firefox/120.0", age: 60 * Self.day)
        try keg("opt/homebrew/Caskroom/firefox/121.0", age: Self.day)
        let cask = tmp.url("opt/homebrew/Caskroom/firefox")
        let packages = [
            try cleanupFinding(formula, name: "node", source: .homebrewFormula(name: "node")),
            try cleanupFinding(cask, name: "firefox", source: .homebrewCask(token: "firefox")),
        ]
        let query = ScriptedCleanupDryRun(items: [
            dryRunItem(Self.oldNodeKeg), dryRunItem("opt/homebrew/Caskroom/firefox/120.0"),
        ])
        let removal = RecordingBrewRemoval()
        let remover = remover(brewQuery: query, brewRemoval: removal)

        for item in packages {
            let outcome = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))
            XCTAssertEqual(outcome, .changedSinceScan, item.tool)
        }

        XCTAssertEqual(removal.calls, [])
        XCTAssertEqual(query.calls, [], "the recent upgrade is a local check, made before Homebrew is asked")
    }

    /// A package directory that cannot be listed could hide a recent upgrade, so the removal fails
    /// instead of reading it as a package without versions.
    func testUnlistablePackageDirectoryAbortsCleanup() async throws {
        try XCTSkipIf(geteuid() == 0, "root can list a 000 directory")
        let package = try nodeKegs(newestAge: Self.day)
        let item = try cleanupFinding(package, name: "node", source: .homebrewFormula(name: "node"))
        let query = ScriptedCleanupDryRun(items: [dryRunItem(Self.oldNodeKeg)])
        let removal = RecordingBrewRemoval()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: package.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path) }

        let outcome = await remover(brewQuery: query, brewRemoval: removal)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .failed("CleanupFileSystemError.io"))
        XCTAssertEqual(query.calls, [])
        XCTAssertEqual(removal.calls, [])
    }

    /// `brew cleanup` never touches the current version, so only the old versions the dry run
    /// lists are checked for use, not the package directory.
    func testRunningCurrentVersionDoesNotBlockCleanup() async throws {
        let package = try nodeKegs(newestAge: 20 * Self.day)
        let current = CleanupProcess(
            pid: 4100, name: "node", executablePath: tmp.url("\(Self.currentNodeKeg)/bin/tool").path,
            arguments: ["node", tmp.url("Dev/app/server.js").path]
        )
        let removal = RecordingBrewRemoval()
        let item = try cleanupFinding(package, name: "node", source: .homebrewFormula(name: "node"))

        let outcome = await remover(
            processes: [current], brewQuery: ScriptedCleanupDryRun(items: [dryRunItem(Self.oldNodeKeg)]), brewRemoval: removal
        ).execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(removal.calls, ["cleanup:node"])
    }

    func testRunningOldVersionNeedsAcknowledgement() async throws {
        let package = try nodeKegs(newestAge: 20 * Self.day)
        let old = CleanupProcess(
            pid: 4101, name: "node", executablePath: tmp.url("\(Self.oldNodeKeg)/bin/tool").path, arguments: ["node"]
        )
        let removal = RecordingBrewRemoval()
        let remover = remover(
            processes: [old], brewQuery: ScriptedCleanupDryRun(items: [dryRunItem(Self.oldNodeKeg)]), brewRemoval: removal
        )
        let item = try cleanupFinding(package, name: "node", source: .homebrewFormula(name: "node"))

        let first = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))

        XCTAssertEqual(first, .needsInUseAcknowledgement([old]))
        XCTAssertEqual(removal.calls, [])

        let second = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(second, .removed)
        XCTAssertEqual(removal.calls, ["cleanup:node"])
    }

    /// A name the gate refuses is never queried, dry-run or passed to `brew`, whatever the action.
    func testInvalidHomebrewNameNeverReachesBrew() async throws {
        let package = try nodeKegs(newestAge: 20 * Self.day)
        let query = ScriptedCleanupDryRun(items: [dryRunItem(Self.oldNodeKeg)])
        let removal = RecordingBrewRemoval()
        let remover = remover(brewQuery: query, brewRemoval: removal)
        let actions: [CleanupBrewAction] = [
            .cleanup("--prune=all"), .cleanup("node;rm"), .uninstallFormula("-rf"), .uninstallFormula("a//b"),
            .uninstallCask("../node"), .uninstallCask(""),
        ]

        for action in actions {
            let item = finding(
                path: package, source: .homebrewFormula(name: "node"), action: .brew(action),
                identity: try identity(of: package), detector: .homebrew, status: .unused
            )
            let outcome = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))
            XCTAssertEqual(outcome, .notRemovable, "\(action)")
        }

        XCTAssertEqual(query.calls, [])
        XCTAssertEqual(removal.calls, [])
    }

    func testNewlyReferencedDistributionIsNotTrashed() async throws {
        let distribution = try gradleDistribution("gradle-8.10-bin")
        let item = try leftoverFinding(distribution, detector: .gradle, tool: "gradle", reason: .unusedGradleDistribution)
        let recheck = FixedReferenceRecheck(stillUnreferenced: false)

        let outcome = await remover(referenceRecheck: recheck)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(trash.urls, [])
        XCTAssertEqual(recheck.asked, [item])
    }

    func testNewlyNeededJDKOrIDEFolderIsNotTrashed() async throws {
        let jdk = try tmp.directory(".gradle/jdks/eclipse_adoptium-21-aarch64-os_x.2")
        let folder = try jetBrainsFolder("Library/Caches/JetBrains/IntelliJIdea2025.3")
        let items = [
            try leftoverFinding(jdk, detector: .gradle, tool: "java", reason: .unreferencedJDK(major: 21)),
            try leftoverFinding(folder, detector: .jetBrains, tool: "IntelliJIdea", reason: .ideVersionNotInstalled(installed: ["2026.3"])),
        ]
        let recheck = FixedReferenceRecheck(stillUnreferenced: false)
        let remover = remover(referenceRecheck: recheck)

        for item in items {
            let outcome = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))
            XCTAssertEqual(outcome, .changedSinceScan, item.tool)
        }

        XCTAssertEqual(trash.urls, [])
        XCTAssertEqual(recheck.asked, items)
    }

    /// Only D6 and D7 judged their item from what referenced it at scan time; an item that is still
    /// unreferenced goes to the Trash.
    func testReferenceRecheckIsAskedOnlyForGradleAndJetBrainsItems() async throws {
        try installClaude(versions: ["2.1.318", "2.1.325"], current: "2.1.325")
        let version = try versionFinding(tmp.url(".local/share/claude/versions/2.1.318"))
        let refusing = FixedReferenceRecheck(stillUnreferenced: false)
        let versionOutcome = await remover(referenceRecheck: refusing)
            .execute(CleanupRemovalIntent(finding: version, inUseAcknowledged: true))
        XCTAssertEqual(versionOutcome, .removed)
        XCTAssertEqual(refusing.asked, [], "a D3 item has no references to re-check")

        let distribution = try gradleDistribution("gradle-8.10-bin")
        let item = try leftoverFinding(distribution, detector: .gradle, tool: "gradle", reason: .unusedGradleDistribution)
        let confirming = FixedReferenceRecheck(stillUnreferenced: true)
        let outcome = await remover(referenceRecheck: confirming)
            .execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(confirming.asked, [item])
        XCTAssertEqual(trash.urls, [version.path, distribution])
    }

    /// A Gradle daemon names its distribution only inside `-javaagent:` (or a classpath), and an
    /// IDE its folders inside `-D` properties; the scan counted those, so the removal does too.
    func testProcessNamingTheItemOnlyInsideAnArgumentNeedsAcknowledgement() async throws {
        let distribution = try gradleDistribution("gradle-8.10-bin")
        let folder = try jetBrainsFolder("Library/Caches/JetBrains/IntelliJIdea2025.3")
        let daemon = CleanupProcess(
            pid: 5100, name: "java", executablePath: "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java",
            arguments: [
                "java", "-javaagent:\(distribution.path)/a1b2c3/gradle-8.10/lib/agents/gradle-instrumentation-agent-8.10.jar",
                "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.10",
            ]
        )
        let ide = CleanupProcess(
            pid: 5200, name: "idea", executablePath: "/Applications/IntelliJ IDEA 2025.3.app/Contents/MacOS/idea",
            arguments: ["idea", "-Didea.system.path=\(folder.path)"]
        )
        let cases = [
            (item: try leftoverFinding(distribution, detector: .gradle, tool: "gradle", reason: .unusedGradleDistribution), user: daemon),
            (item: try leftoverFinding(folder, detector: .jetBrains, tool: "IntelliJIdea", reason: .ideNotFound), user: ide),
        ]
        let remover = remover(processes: [daemon, ide], referenceRecheck: FixedReferenceRecheck(stillUnreferenced: true))

        for (item, user) in cases {
            let first = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: false))
            XCTAssertEqual(first, .needsInUseAcknowledgement([user]), item.tool)
            XCTAssertEqual(trash.urls, [], item.tool)
        }
        for (item, _) in cases {
            let second = await remover.execute(CleanupRemovalIntent(finding: item, inUseAcknowledged: true))
            XCTAssertEqual(second, .removed, item.tool)
        }
        XCTAssertEqual(trash.urls, [distribution, folder])
    }

    // MARK: Helpers

    private func remover(
        processes: [CleanupProcess] = [],
        brewQuery: CleanupBrewQuerying = ScriptedBrewQuery(),
        brewRemoval: CleanupBrewRemoving = RecordingBrewRemoval(),
        referenceRecheck: CleanupReferenceRechecking
    ) -> CleanupRemover {
        CleanupRemover(
            fileSystem: fileSystem,
            inspector: FakeProcessInspector(processes: processes, bootTime: Date(timeIntervalSince1970: 0)),
            brewQuery: brewQuery, brewRemoval: brewRemoval, coordinator: coordinator, home: tmp.home,
            today: { Self.november16Noon }, referenceRecheck: referenceRecheck
        )
    }

    /// `Cellar/node` with an old keg two months old and the current keg `newestAge` old, both
    /// dated against the remover's `today`.
    private func nodeKegs(newestAge: TimeInterval) throws -> URL {
        try keg(Self.oldNodeKeg, age: 60 * Self.day)
        try keg(Self.currentNodeKeg, age: newestAge)
        return tmp.url("opt/homebrew/Cellar/node")
    }

    /// A version directory holding one executable. Its date is set after its contents, because
    /// writing inside a directory moves the date.
    private func keg(_ relative: String, age: TimeInterval) throws {
        try tmp.file("\(relative)/bin/tool", size: 64, executable: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.november16Noon.addingTimeInterval(-age)], ofItemAtPath: tmp.url(relative).path
        )
    }

    private func dryRunItem(_ relative: String) -> CleanupBrewCleanupItem {
        CleanupBrewCleanupItem(path: tmp.url(relative), size: 60_000_000)
    }

    /// A D4 finding for the package directory, as the scan identified it.
    private func cleanupFinding(_ package: URL, name: String, source: CleanupSource) throws -> CleanupFinding {
        CleanupFinding(
            detector: .homebrew, tool: name, path: package, realpath: nil, source: source, version: nil, size: nil,
            status: .unused, reason: .homebrewLeftovers(items: 1), action: .brew(.cleanup(name)), risk: .low,
            bucket: .needsDecision, identity: try identity(of: package)
        )
    }

    /// A D6 or D7 finding that trashes `url`, identified as the scan saw it.
    private func leftoverFinding(
        _ url: URL, detector: CleanupDetectorID, tool: String, reason: CleanupReason
    ) throws -> CleanupFinding {
        CleanupFinding(
            detector: detector, tool: tool, path: url, realpath: nil, source: nil, version: nil, size: nil,
            status: .unused, reason: reason, action: .trash([url]), risk: .low, bucket: .needsDecision,
            identity: try identity(of: url)
        )
    }

    /// A distribution as the wrapper unpacks it: `dists/<name>/<hash>/<name without type>/…`.
    private func gradleDistribution(_ name: String) throws -> URL {
        try tmp.file(".gradle/wrapper/dists/\(name)/a1b2c3/gradle-8.10/lib/gradle-core.jar", size: 8192)
        return tmp.url(".gradle/wrapper/dists/\(name)")
    }

    private func jetBrainsFolder(_ relative: String) throws -> URL {
        try tmp.file("\(relative)/options/ide.general.xml", size: 2048)
        return tmp.url(relative)
    }
}
