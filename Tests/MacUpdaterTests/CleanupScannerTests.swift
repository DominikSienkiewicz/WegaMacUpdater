import XCTest
@testable import MacUpdaterCore

private final class RecordingBrew: CleanupBrewQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var calls: [String] { lock.withLock { recorded } }

    func usesInstalled(formula: String) async throws -> [String] {
        lock.withLock { recorded.append(formula) }
        return []
    }

    func cleanupDryRun(package: String?) async throws -> [CleanupBrewCleanupItem] { [] }
    func autoremoveDryRun() async throws -> [String] { [] }
}

/// The reference Mac on top of the temporary home: a virtual `/usr/bin/git` (with its ancestors,
/// for the guard's hop-by-hop walk) so the system copy exists without reading the real `/usr/bin`,
/// fixed allocated sizes, an optional path that fails with a given error, an optional cancellation
/// of the running task on the first sizing call, and a record of every mutating call.
private final class ReferenceFileSystem: CleanupFileSystem, @unchecked Sendable {
    static let systemDirectory = "/usr/bin"
    static let systemTool = "/usr/bin/git"
    private static let virtualDirectories = ["/usr": UInt64(9001), "/usr/bin": 9002]

    private let base: CleanupFileSystem
    private let sizes: [String: Int64]
    private let failure: (path: String, error: Error)?
    private let cancelsWhenSizing: Bool
    private let lock = NSLock()
    private var recordedMutations: [String] = []
    private var recordedSizeCalls = 0

    init(base: CleanupFileSystem, sizes: [String: Int64], failure: (path: String, error: Error)?, cancelsWhenSizing: Bool) {
        self.base = base
        self.sizes = sizes
        self.failure = failure
        self.cancelsWhenSizing = cancelsWhenSizing
    }

    var mutations: [String] { lock.withLock { recordedMutations } }
    var sizeCalls: Int { lock.withLock { recordedSizeCalls } }

    func entry(at url: URL) throws -> CleanupEntry? {
        let path = try checked(url)
        if let inode = Self.virtualDirectories[path] {
            return CleanupEntry(url: url, kind: .directory, isExecutable: true, identity: CleanupFileIdentity(device: 1, inode: inode), modificationDate: nil)
        }
        if path == Self.systemTool {
            return CleanupEntry(url: url, kind: .file, isExecutable: true, identity: CleanupFileIdentity(device: 1, inode: 9003), modificationDate: nil)
        }
        return try base.entry(at: url)
    }

    func contents(of directory: URL) throws -> [CleanupEntry] {
        let path = try checked(directory)
        if path == Self.systemDirectory {
            let tool = directory.appending(component: "git", directoryHint: .notDirectory)
            return try [entry(at: tool)].compactMap { $0 }
        }
        return try base.contents(of: directory)
    }

    func symlinkDestination(of url: URL) throws -> String {
        try base.symlinkDestination(of: url)
    }

    func realpath(_ url: URL) throws -> URL {
        try base.realpath(url)
    }

    func allocatedSize(of url: URL) throws -> Int64 {
        lock.withLock { recordedSizeCalls += 1 }
        if cancelsWhenSizing {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        return try sizes[ProtectedLocationGuard.standardizedPath(url)] ?? base.allocatedSize(of: url)
    }

    func readText(_ url: URL, maxBytes: Int) throws -> String {
        try base.readText(url, maxBytes: maxBytes)
    }

    func createDirectory(_ url: URL) throws {
        recordMutation("createDirectory", url)
        try base.createDirectory(url)
    }

    func moveItem(_ source: URL, to destination: URL) throws {
        recordMutation("moveItem", source)
        try base.moveItem(source, to: destination)
    }

    func trash(_ url: URL) throws {
        recordMutation("trash", url)
        try base.trash(url)
    }

    private func checked(_ url: URL) throws -> String {
        let path = ProtectedLocationGuard.standardizedPath(url)
        if let failure, failure.path == path { throw failure.error }
        return path
    }

    private func recordMutation(_ operation: String, _ url: URL) {
        lock.withLock { recordedMutations.append("\(operation) \(url.path)") }
    }
}

final class CleanupScannerTests: XCTestCase {
    private static let bootMilliseconds: Int64 = 1_794_297_600_000
    private static let scanDate = Date(timeIntervalSince1970: 1_794_300_000)

    private var tmp: CleanupTempHome!
    private var trash: RecordingTrash!
    private var brew: RecordingBrew!
    private var reference: ReferenceFileSystem!
    private var recording: RecordingCleanupFileSystem!

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        trash = RecordingTrash()
        brew = RecordingBrew()
    }

    private var fnmDirectory: URL { tmp.url(".local/state/fnm_multishells") }
    private var staleEntries: [URL] {
        [
            fnmDirectory.appending(component: "81234_\(Self.bootMilliseconds - 86_400_000)", directoryHint: .notDirectory),
            fnmDirectory.appending(component: "81235_\(Self.bootMilliseconds - 1_000)_ab12", directoryHint: .notDirectory),
        ]
    }

    private var inUseProcess: CleanupProcess {
        let old = tmp.url(".local/share/claude/versions/2.1.318").path
        return CleanupProcess(pid: 4242, name: "claude", executablePath: old, arguments: [old, "--chrome-native-host"])
    }

    /// Sizes whose decimal digits name the item, so a wrong sum shows which one slipped in.
    private var referenceSizes: [String: Int64] {
        var sizes: [String: Int64] = [
            tmp.url(".local/share/claude/versions/2.1.318").path: 1,
            tmp.url(".local/share/claude/versions/2.1.322").path: 20,
            tmp.url("opt/homebrew/Caskroom/claude-code/2.1.311").path: 300,
            tmp.url("Library/Application Support/Claude/claude-code").path: 4_000,
            tmp.url("Library/Application Support/Claude/claude-code-vm").path: 50_000,
            tmp.url("opt/homebrew/Cellar/gh/2.104.0").path: 600_000,
        ]
        for entry in staleEntries { sizes[entry.path] = 7_000_000 }
        return sizes
    }

    /// Brief §3 cases 1–6, 8 and 12 on a synthetic home; returns the `PATH`.
    private func buildReferenceTree() throws -> [String] {
        for version in ["2.1.318", "2.1.322", "2.1.325"] {
            try tmp.file(".local/share/claude/versions/\(version)", size: 16, executable: true)
        }
        try tmp.symlink(".local/bin/claude", to: tmp.url(".local/share/claude/versions/2.1.325").path)
        let cask = try tmp.file("opt/homebrew/Caskroom/claude-code/2.1.311/claude", size: 16, executable: true)
        try tmp.symlink("opt/homebrew/bin/claude", to: cask.path)
        try tmp.file("Library/Application Support/Claude/claude-code/2.1.1/f3a9/claude.app/Contents/MacOS/claude", size: 16, executable: true)
        try tmp.file("Library/Application Support/Claude/claude-code-vm/2.1.1/claude", size: 16, executable: true)
        try tmp.file(".local/bin/gh", size: 16, executable: true)
        let gh = try tmp.file("opt/homebrew/Cellar/gh/2.104.0/bin/gh", size: 16, executable: true)
        try tmp.symlink("opt/homebrew/bin/gh", to: gh.path)
        let ollama = try tmp.file("opt/homebrew/Cellar/ollama/0.40.16/bin/ollama", size: 16, executable: true)
        try tmp.symlink("opt/homebrew/bin/ollama", to: ollama.path)
        let app = try tmp.file("Applications/Ollama.app/Contents/Resources/ollama", size: 16, executable: true)
        try tmp.symlink("usr/local/bin/ollama", to: app.path)
        let git = try tmp.file("opt/homebrew/Cellar/git/2.50.0/bin/git", size: 16, executable: true)
        try tmp.symlink("opt/homebrew/bin/git", to: git.path)
        for entry in staleEntries {
            try tmp.symlink(".local/state/fnm_multishells/\(entry.lastPathComponent)", to: tmp.url("node").path)
        }
        try tmp.symlink(".local/state/fnm_multishells/81236_\(Self.bootMilliseconds + 60_000)", to: tmp.url("node").path)
        return [
            tmp.url(".local/bin").path, tmp.url("opt/homebrew/bin").path, tmp.url("usr/local/bin").path,
            ReferenceFileSystem.systemDirectory,
        ]
    }

    private func context(
        path entries: [String], failure: (path: String, error: Error)? = nil, cancelsWhenSizing: Bool = false,
        isApproximate: Bool = false
    ) -> CleanupContext {
        let trash = self.trash!
        reference = ReferenceFileSystem(
            base: LiveCleanupFileSystem(trash: { trash.record($0) }), sizes: referenceSizes,
            failure: failure, cancelsWhenSizing: cancelsWhenSizing
        )
        recording = RecordingCleanupFileSystem(wrapping: reference)
        return CleanupContext(
            home: tmp.home, tmpDirectory: tmp.url("tmp"),
            path: CleanupPathSnapshot(
                entries: entries, ignoredEntries: [], shell: isApproximate ? nil : "zsh",
                capturedAt: isApproximate ? nil : Self.scanDate, isApproximate: isApproximate
            ),
            fileSystem: GuardedCleanupFileSystem(
                base: recording, guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
            ),
            inspector: FakeProcessInspector(
                processes: [inUseProcess], bootTime: Date(timeIntervalSince1970: Double(Self.bootMilliseconds) / 1000)
            ),
            brew: brew, brewPrefix: tmp.url("opt/homebrew")
        )
    }

    /// Runs in its own task so a cancellation never reaches the test's task.
    private func scan(_ context: CleanupContext) async -> Result<CleanupReport, Error> {
        await Task { try await CleanupScanner(now: { Self.scanDate }).scan(context) }.result
    }

    private func finding(
        _ detector: CleanupDetectorID, _ path: String, in report: CleanupReport, line: UInt = #line
    ) throws -> CleanupFinding {
        try XCTUnwrap(
            report.findings.first { $0.detector == detector && $0.path.path == path },
            "no \(detector.rawValue) finding for \(path)", line: line
        )
    }

    private func treeListing() throws -> [String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: tmp.home, includingPropertiesForKeys: nil))
        return enumerator.compactMap { ($0 as? URL)?.path }.sorted()
    }

    func testFullScanOverTheReferenceTreeFindsStageOneCases() async throws {
        let path = try buildReferenceTree()
        let before = try treeListing()

        let report = try await scan(context(path: path)).get()

        let home = { (relative: String) in self.tmp.url(relative).path }
        let older = try finding(.versionDirectories, home(".local/share/claude/versions/2.1.322"), in: report)
        XCTAssertEqual(older.status, .unused, "case 1")
        XCTAssertEqual(older.reason, .olderVersion(current: "2.1.325"))
        XCTAssertEqual(older.bucket, .safe)
        XCTAssertEqual(try finding(.versionDirectories, home(".local/share/claude/versions/2.1.325"), in: report).status, .active)
        let mapped = try finding(.versionDirectories, home(".local/share/claude/versions/2.1.318"), in: report)
        XCTAssertEqual(mapped.status, .inUse([inUseProcess]), "case 2")
        XCTAssertEqual(mapped.bucket, .needsDecision)
        let cask = try finding(.pathDuplicates, home("opt/homebrew/bin/claude"), in: report)
        XCTAssertEqual(cask.status, .shadowed, "case 3")
        XCTAssertEqual(cask.action, .brew(.uninstallCask("claude-code")))
        XCTAssertEqual(cask.bucket, .safe)
        XCTAssertEqual(try finding(.pathDuplicates, home(".local/bin/claude"), in: report).status, .active)
        for owned in ["claude-code", "claude-code-vm"] {
            let managed = try finding(.versionDirectories, home("Library/Application Support/Claude/\(owned)"), in: report)
            XCTAssertEqual(managed.status, .appManaged, "case 4")
            XCTAssertEqual(managed.bucket, .excluded)
        }
        let gh = try finding(.pathDuplicates, home("opt/homebrew/bin/gh"), in: report)
        XCTAssertEqual(gh.status, .shadowed, "case 5")
        XCTAssertEqual(gh.action, .brew(.uninstallFormula("gh")))
        XCTAssertEqual(try finding(.pathDuplicates, home(".local/bin/gh"), in: report).status, .active)
        let appLink = try finding(.pathDuplicates, home("usr/local/bin/ollama"), in: report)
        XCTAssertEqual(appLink.status, .shadowed, "case 6")
        XCTAssertEqual(appLink.action, .instruction(.removeAppLinkWithAdminRights(link: home("usr/local/bin/ollama"))))
        XCTAssertEqual(try finding(.pathDuplicates, home("opt/homebrew/bin/ollama"), in: report).status, .active)
        XCTAssertEqual(try finding(.pathDuplicates, ReferenceFileSystem.systemTool, in: report).status, .expected, "case 8")
        XCTAssertEqual(try finding(.pathDuplicates, home("opt/homebrew/bin/git"), in: report).status, .active)
        let shellState = report.findings.filter { $0.detector == .shellState }
        XCTAssertEqual(shellState.map(\.status), [.stale, .info], "case 12")
        XCTAssertEqual(shellState.map(\.reason), [.staleSinceBoot(count: 2), .keptSinceBoot(count: 1)])
        XCTAssertEqual(shellState.first?.bucket, .safe)

        XCTAssertEqual(report.totals, CleanupTotals(safe: 20 + 300 + 2 * 7_000_000, needsDecision: 1 + 600_000))
        XCTAssertEqual(
            report.findings.map(\.detector).reduce(into: [CleanupDetectorID]()) { if $0.last != $1 { $0.append($1) } },
            [.pathDuplicates, .versionDirectories, .shellState]
        )
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.createdAt, Self.scanDate)
        XCTAssertEqual(report.path.entries, path)
        XCTAssertEqual(report.notes, [])
        XCTAssertEqual(report.skippedProtected, [])
        XCTAssertEqual(brew.calls, ["gh"])

        XCTAssertEqual(trash.urls, [], "the scan never moves anything to the Trash")
        XCTAssertEqual(reference.mutations, [], "the scan never creates or moves anything")
        XCTAssertEqual(try treeListing(), before)
    }

    /// The approximate `PATH` puts `/etc/paths` first, so its active copy may not be the one a
    /// Terminal runs: no D1 copy counts as safe then, while its action stays as it is.
    func testApproximatePathNeverMakesADuplicateSafe() async throws {
        let path = try buildReferenceTree()

        let captured = try await scan(context(path: path)).get()
        let approximate = try await scan(context(path: path, isApproximate: true)).get()

        let cask = tmp.url("opt/homebrew/bin/claude").path
        XCTAssertEqual(try finding(.pathDuplicates, cask, in: captured).bucket, .safe, "precondition")
        let approximated = try finding(.pathDuplicates, cask, in: approximate)
        XCTAssertEqual(approximated.bucket, .needsDecision)
        XCTAssertEqual(approximated.action, .brew(.uninstallCask("claude-code")))
        XCTAssertFalse(approximate.findings.contains { $0.detector == .pathDuplicates && $0.bucket == .safe })
        let older = try finding(.versionDirectories, tmp.url(".local/share/claude/versions/2.1.322").path, in: approximate)
        XCTAssertEqual(older.bucket, .safe, "a version directory does not depend on the PATH order")
        XCTAssertEqual(approximate.totals, CleanupTotals(safe: 20 + 2 * 7_000_000, needsDecision: 1 + 300 + 600_000))
    }

    func testScanNeverTouchesProtectedLocations() async throws {
        var path = try buildReferenceTree()
        try tmp.file("Documents/bin/claude", size: 16, executable: true)
        try tmp.file("Desktop/x", size: 16)
        try tmp.file("Library/Mobile Documents/y", size: 16)
        try tmp.file("Downloads/bin/claude", size: 16, executable: true)
        let hidden = try tmp.file("Documents/z", size: 16, executable: true)
        try tmp.symlink(".local/bin/z", to: hidden.path)
        try tmp.file("opt/homebrew/bin/z", size: 16, executable: true)
        let downloads = tmp.url("Downloads/bin").path
        path.insert(downloads, at: 1)

        let report = try await scan(context(path: path)).get()

        XCTAssertEqual(report.skippedProtected, [downloads, tmp.url("Documents").path])
        XCTAssertEqual(try finding(.pathDuplicates, tmp.url(".local/bin/z").path, in: report).status, .brokenLink)
        XCTAssertTrue(recording.touched.contains(tmp.url(".local/bin").path), "the recording file system was never reached")
        let roots = ProtectedLocationGuard.protectedRoots(home: tmp.home).map(CleanupPathText.components(of:))
        let offenders = recording.touched.filter { touched in
            roots.contains { CleanupPathText.components(of: touched).starts(with: $0) }
        }
        XCTAssertEqual(offenders, [], "the base file system received a protected path")
        XCTAssertEqual(trash.urls, [])
    }

    func testOneFailingDetectorDoesNotSinkTheScan() async throws {
        let path = try buildReferenceTree()

        let failure = (path: fnmDirectory.path, error: CleanupFileSystemError.io(fnmDirectory.path) as Error)
        let report = try await scan(context(path: path, failure: failure)).get()

        XCTAssertEqual(report.notes, [CleanupDetectorNote(detector: .shellState, kind: .failed)])
        XCTAssertFalse(report.findings.contains { $0.detector == .shellState })
        XCTAssertTrue(report.findings.contains { $0.detector == .pathDuplicates })
        XCTAssertTrue(report.findings.contains { $0.detector == .versionDirectories })
        XCTAssertEqual(report.totals.safe, 20 + 300)
    }

    func testACancellationInsideADetectorIsNotTurnedIntoANote() async throws {
        let path = try buildReferenceTree()

        let failure = (path: fnmDirectory.path, error: CancellationError() as Error)
        let result = await scan(context(path: path, failure: failure))

        guard case .failure(let error) = result else {
            return XCTFail("a detector's CancellationError became a report")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
    }

    func testCancellationThrowsAndProducesNoReport() async throws {
        let path = try buildReferenceTree()

        let result = await scan(context(path: path, cancelsWhenSizing: true))

        switch result {
        case .success:
            XCTFail("a cancelled scan returned a report")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertGreaterThan(reference.sizeCalls, 0, "the task must be cancelled while sizing")
        XCTAssertEqual(brew.calls, [], "no detector starts after the cancellation")
        XCTAssertFalse(recording.touched.contains(fnmDirectory.path), "the shell-state detector must not run")
    }
}
