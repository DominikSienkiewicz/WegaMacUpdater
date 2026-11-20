import XCTest
@testable import MacUpdaterCore

/// A clean Homebrew (Brief case 15): both dry runs find nothing. `calls` lists the formulae D1
/// asked about; `dryRuns` the dry runs D4 asked for.
private final class RecordingBrew: CleanupBrewQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var recordedDryRuns: [String] = []

    var calls: [String] { lock.withLock { recorded } }
    var dryRuns: [String] { lock.withLock { recordedDryRuns } }

    func usesInstalled(formula: String) async throws -> [String] {
        lock.withLock { recorded.append(formula) }
        return []
    }

    func cleanupDryRun(package: String?) async throws -> [CleanupBrewCleanupItem] {
        lock.withLock { recordedDryRuns.append(package.map { "cleanup \($0)" } ?? "cleanup") }
        return []
    }

    func autoremoveDryRun() async throws -> [String] {
        lock.withLock { recordedDryRuns.append("autoremove") }
        return []
    }
}

/// The reference Mac on top of the temporary home: a virtual `/usr/bin/git` (with its ancestors,
/// for the guard's hop-by-hop walk) so the system copy exists without reading the real `/usr/bin`,
/// a virtual `/Library` holding only the given system JDK bundles (empty ones, so D6 reads their
/// major from the name) so the host's own JDKs never show, fixed allocated sizes, an optional path
/// that fails with a given error, an optional cancellation of the running task on the first sizing
/// call or when one directory is listed, and a record of every mutating call.
private final class ReferenceFileSystem: CleanupFileSystem, @unchecked Sendable {
    static let systemDirectory = "/usr/bin"
    static let systemTool = "/usr/bin/git"
    static let systemJDKDirectory = "/Library/Java/JavaVirtualMachines"
    private static let systemLibrary = "Library"

    private let base: CleanupFileSystem
    private let sizes: [String: Int64]
    private let failure: (path: String, error: Error)?
    private let cancelsWhenSizing: Bool
    private let cancelsWhenListing: String?
    private let virtualDirectories: [String: UInt64]
    private let virtualListings: [String: [String]]
    private let lock = NSLock()
    private var recordedMutations: [String] = []
    private var recordedSizeCalls = 0

    init(
        base: CleanupFileSystem, sizes: [String: Int64], failure: (path: String, error: Error)?, cancelsWhenSizing: Bool,
        systemJDKs: [String] = [], cancelsWhenListing: String? = nil
    ) {
        self.base = base
        self.sizes = sizes
        self.failure = failure
        self.cancelsWhenSizing = cancelsWhenSizing
        self.cancelsWhenListing = cancelsWhenListing
        let bundles = systemJDKs.map { "\(Self.systemJDKDirectory)/\($0)" }
        var directories: [String: UInt64] = [
            "/usr": 9001, "/usr/bin": 9002, "/Library": 9004, "/Library/Java": 9005, Self.systemJDKDirectory: 9006,
        ]
        var listings: [String: [String]] = [
            Self.systemDirectory: ["git"], "/Library": ["Java"], "/Library/Java": ["JavaVirtualMachines"],
            Self.systemJDKDirectory: systemJDKs,
        ]
        for (offset, bundle) in bundles.enumerated() {
            directories[bundle] = 9100 + UInt64(offset)
            listings[bundle] = []
        }
        virtualDirectories = directories
        virtualListings = listings
    }

    var mutations: [String] { lock.withLock { recordedMutations } }
    var sizeCalls: Int { lock.withLock { recordedSizeCalls } }

    func entry(at url: URL) throws -> CleanupEntry? {
        let path = try checked(url)
        if let inode = virtualDirectories[path] {
            return CleanupEntry(url: url, kind: .directory, isExecutable: true, identity: CleanupFileIdentity(device: 1, inode: inode), modificationDate: nil)
        }
        if path == Self.systemTool {
            return CleanupEntry(url: url, kind: .file, isExecutable: true, identity: CleanupFileIdentity(device: 1, inode: 9003), modificationDate: nil)
        }
        if Self.isUnderSystemLibrary(path) { return nil }
        return try base.entry(at: url)
    }

    func contents(of directory: URL) throws -> [CleanupEntry] {
        let path = try checked(directory)
        if let names = virtualListings[path] {
            return try names.compactMap { try entry(at: directory.appending(component: $0, directoryHint: .notDirectory)) }
        }
        if Self.isUnderSystemLibrary(path) { throw CleanupFileSystemError.notFound(path) }
        if path == cancelsWhenListing {
            withUnsafeCurrentTask { $0?.cancel() }
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
        let path = ProtectedLocationGuard.standardizedPath(url)
        if Self.isUnderSystemLibrary(path) { throw CleanupFileSystemError.notFound(path) }
        return try base.readText(url, maxBytes: maxBytes)
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

    private static func isUnderSystemLibrary(_ path: String) -> Bool {
        CleanupPathText.components(of: path).first == systemLibrary
    }
}

/// The stage-2 inputs of a scan: project roots and application folders (relative to the home), the
/// virtual system JDK bundles, sizes on top of the stage-1 ones, and the directory (relative to the
/// home) whose listing cancels the scan.
private struct SpaceSetup {
    var projectRoots = ["Dev"]
    var applicationDirectories: [String] = []
    var systemJDKs: [String] = []
    var sizes: [String: Int64] = [:]
    var cancelsWhenListing: String?
}

/// A failure of the map's reader that is not a database error, so D10 rethrows it.
private struct MapReaderFault: Error {}

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

    /// Brief §3 cases 1–6, 8 and 12 on a synthetic home, with an empty `~/Dev` project root; returns the `PATH`.
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
        try tmp.directory("Dev")
        return [
            tmp.url(".local/bin").path, tmp.url("opt/homebrew/bin").path, tmp.url("usr/local/bin").path,
            ReferenceFileSystem.systemDirectory,
        ]
    }

    private func context(
        path entries: [String], failure: (path: String, error: Error)? = nil, cancelsWhenSizing: Bool = false,
        isApproximate: Bool = false, space: SpaceSetup = SpaceSetup(), tccMap: CleanupTCCDatabaseReading? = nil
    ) -> CleanupContext {
        let trash = self.trash!
        reference = ReferenceFileSystem(
            base: LiveCleanupFileSystem(trash: { trash.record($0) }), sizes: referenceSizes.merging(space.sizes) { $1 },
            failure: failure, cancelsWhenSizing: cancelsWhenSizing,
            systemJDKs: space.systemJDKs, cancelsWhenListing: space.cancelsWhenListing.map { tmp.url($0).path }
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
            brew: brew, brewPrefix: tmp.url("opt/homebrew"),
            projectRoots: space.projectRoots.map { tmp.url($0) },
            applicationDirectories: space.applicationDirectories.map { tmp.url($0) },
            tccMap: tccMap, systemConfigurationDirectory: tmp.url("etc")
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
        XCTAssertEqual(
            appLink.action,
            .uninstallApp(name: "Ollama", bundle: tmp.home.appending(path: "Applications/Ollama.app", directoryHint: .isDirectory))
        )
        XCTAssertEqual(try finding(.pathDuplicates, home("opt/homebrew/bin/ollama"), in: report).status, .active)
        XCTAssertEqual(try finding(.pathDuplicates, ReferenceFileSystem.systemTool, in: report).status, .expected, "case 8")
        XCTAssertEqual(try finding(.pathDuplicates, home("opt/homebrew/bin/git"), in: report).status, .active)
        let shellState = report.findings.filter { $0.detector == .shellState }
        XCTAssertEqual(shellState.map(\.status), [.stale, .info], "case 12")
        XCTAssertEqual(shellState.map(\.reason), [.staleSinceBoot(count: 2), .keptSinceBoot(count: 1)])
        XCTAssertEqual(shellState.first?.bucket, .safe)

        XCTAssertEqual(report.totals, CleanupTotals(safe: 20 + 300 + 2 * 7_000_000, needsDecision: 1 + 600_000))
        XCTAssertEqual(Set(report.findings.map(\.id)).count, report.findings.count, "finding ids are unique report-wide")
        XCTAssertEqual(
            report.findings.map(\.detector).reduce(into: [CleanupDetectorID]()) { if $0.last != $1 { $0.append($1) } },
            [.pathDuplicates, .versionDirectories, .shellState]
        )
        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.createdAt, Self.scanDate)
        XCTAssertEqual(report.path.entries, path)
        XCTAssertEqual(report.notes, [])
        XCTAssertEqual(report.skippedProtected, [])
        XCTAssertEqual(brew.calls, ["gh", "ollama"], "every Homebrew formula with a rival copy, the active one included")

        XCTAssertEqual(trash.urls, [], "the scan never moves anything to the Trash")
        XCTAssertEqual(reference.mutations, [], "the scan never creates or moves anything")
        XCTAssertEqual(try treeListing(), before)
    }

    /// The approximate `PATH` puts `/etc/paths` first, so its active copy may not be the one a
    /// Terminal runs: Wega keeps no copy on its own then, so no D1 copy is removable or counted
    /// until the user picks the one to keep.
    func testApproximatePathNeverMakesADuplicateSafe() async throws {
        let path = try buildReferenceTree()

        let captured = try await scan(context(path: path)).get()
        let approximate = try await scan(context(path: path, isApproximate: true)).get()

        let cask = tmp.url("opt/homebrew/bin/claude").path
        XCTAssertEqual(try finding(.pathDuplicates, cask, in: captured).bucket, .safe, "precondition")
        let approximated = try finding(.pathDuplicates, cask, in: approximate)
        XCTAssertEqual(approximated.bucket, .excluded)
        XCTAssertEqual(approximated.action, .none)
        XCTAssertEqual(approximated.candidate?.keep, .undecided)
        XCTAssertEqual(approximated.candidate?.removal, .brew(.uninstallCask("claude-code")))
        XCTAssertFalse(approximate.findings.contains { $0.detector == .pathDuplicates && $0.bucket == .safe })
        let older = try finding(.versionDirectories, tmp.url(".local/share/claude/versions/2.1.322").path, in: approximate)
        XCTAssertEqual(older.bucket, .safe, "a version directory does not depend on the PATH order")
        XCTAssertEqual(approximate.totals, CleanupTotals(safe: 20 + 2 * 7_000_000, needsDecision: 1))
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

    // MARK: Stage 2 — space

    private static let oldIntelliJFolders = ["IntelliJIdea2025.3", "IntelliJIdea2026.1", "IntelliJIdea2026.1-backup", "IntelliJIdea2026.2"]
    private static let jetBrainsConfigurations = "Library/Application Support/JetBrains"

    private func uvPython(_ version: String) -> URL {
        tmp.url(".local/share/uv/python/cpython-\(version)-macos-aarch64-none")
    }

    private func gradleDistribution(_ version: String) -> URL {
        tmp.url(".gradle/wrapper/dists/gradle-\(version)-bin")
    }

    private func gradleJDK(_ major: Int) -> URL {
        tmp.url(".gradle/jdks/eclipse_adoptium-\(major)-aarch64-os_x.2")
    }

    /// uv's `~/.local/bin/python3` names 3.15.2; nothing names 3.12.12. Returns the link.
    @discardableResult
    private func installUvPythons() throws -> URL {
        let interpreter = try tmp.file(".local/share/uv/python/cpython-3.15.2-macos-aarch64-none/bin/python3.15", size: 16, executable: true)
        try tmp.file(".local/share/uv/python/cpython-3.12.12-macos-aarch64-none/bin/python3.12", size: 16, executable: true)
        return try tmp.symlink(".local/bin/python3", to: interpreter.path)
    }

    /// A distribution as the wrapper unpacks it: `dists/<name>/<hash>/<name without type>/…`.
    private func installDistribution(_ version: String) throws {
        try tmp.file(".gradle/wrapper/dists/gradle-\(version)-bin/a1b2c3/gradle-\(version)/lib/gradle-core.jar", size: 16)
    }

    @discardableResult
    private func wrapper(project: String, version: String) throws -> URL {
        try tmp.file(
            "Dev/\(project)/gradle/wrapper/gradle-wrapper.properties",
            text: "distributionUrl=https\\://services.gradle.org/distributions/gradle-\(version)-bin.zip\n"
        )
    }

    /// Brief cases 7, 9, 10 and 11 under one home, with a clean Homebrew (case 15) and the projects in `~/Dev`.
    private func buildSpaceTree() throws {
        try installUvPythons()
        for version in ["9.2.0", "9.6.0", "9.6.1", "9.7.0", "9.8.1", "9.8.2"] {
            try installDistribution(version)
        }
        try wrapper(project: "old", version: "9.3.0")
        try wrapper(project: "api", version: "9.7.0")
        try wrapper(project: "web", version: "9.8.2")
        try tmp.file(".gradle/jdks/eclipse_adoptium-25-aarch64-os_x.2/jdk-25.0.1+9/Contents/Home/release", text: "JAVA_VERSION=\"25.0.1\"\n")
        try tmp.file(".gradle/jdks/eclipse_adoptium-26-aarch64-os_x.2/release", text: "JAVA_VERSION=\"26\"\n")
        try tmp.file("Dev/app/build.gradle.kts", text: "kotlin {\n    jvmToolchain(21)\n}\n")
        try tmp.file(
            "Applications/IntelliJ IDEA.app/Contents/Resources/product-info.json",
            text: #"{"name": "IntelliJ IDEA", "version": "2026.3", "dataDirectoryName": "IntelliJIdea2026.3"}"#
        )
        for folder in Self.oldIntelliJFolders + ["IntelliJIdea2026.3"] {
            try tmp.file("\(Self.jetBrainsConfigurations)/\(folder)/options/ide.general.xml", size: 16)
        }
        try tmp.file("opt/homebrew/Cellar/git/2.50.0/bin/git", size: 16, executable: true)
        try tmp.file("opt/homebrew/Caskroom/firefox/120.0/Firefox.app/Contents/MacOS/firefox", size: 16, executable: true)
    }

    /// Sizes whose decimal digits name the item: a 1 is safe, a 2 needs a decision, a 3 is excluded.
    private var spaceSizes: [String: Int64] {
        var sizes: [String: Int64] = [
            gradleDistribution("9.2.0").path: 1, gradleDistribution("9.6.0").path: 10,
            gradleDistribution("9.6.1").path: 100, gradleDistribution("9.8.1").path: 1_000,
            uvPython("3.12.12").path: 2, gradleJDK(25).path: 20, gradleJDK(26).path: 200,
            uvPython("3.15.2").path: 3, gradleDistribution("9.7.0").path: 30, gradleDistribution("9.8.2").path: 300,
        ]
        for (folder, size) in zip(Self.oldIntelliJFolders, [Int64(10_000), 100_000, 1_000_000, 10_000_000]) {
            sizes[tmp.url("\(Self.jetBrainsConfigurations)/\(folder)").path] = size
        }
        return sizes
    }

    private func trashedPaths(_ finding: CleanupFinding) -> [String]? {
        guard case .trash(let urls) = finding.action else { return nil }
        return urls.map(\.path)
    }

    func testSpaceDetectorsReportOnTheReferenceMac() async throws {
        try buildSpaceTree()
        let before = try treeListing()

        let report = try await scan(context(path: [], space: SpaceSetup(
            applicationDirectories: ["Applications"], systemJDKs: ["temurin-27.jdk"], sizes: spaceSizes
        ))).get()

        XCTAssertEqual(brew.dryRuns, ["cleanup", "autoremove"], "case 15: D4 asks Homebrew")
        XCTAssertFalse(report.findings.contains { $0.detector == .homebrew }, "case 15: a clean Homebrew leaves nothing")
        let oldPython = try finding(.runtimeVersions, uvPython("3.12.12").path, in: report)
        XCTAssertEqual(oldPython.status, .unused, "case 7")
        XCTAssertEqual(oldPython.action, .command("uv python uninstall 3.12.12"))
        XCTAssertEqual(oldPython.bucket, .needsDecision)
        XCTAssertEqual(
            try finding(.runtimeVersions, uvPython("3.15.2").path, in: report).status, .pinned(by: [tmp.url(".local/bin/python3").path])
        )
        for version in ["9.2.0", "9.6.0", "9.6.1", "9.8.1"] {
            let unused = try finding(.gradle, gradleDistribution(version).path, in: report)
            XCTAssertEqual(unused.status, .unused, "case 9: \(version)")
            XCTAssertEqual(unused.bucket, .safe, "case 9: \(version)")
            XCTAssertEqual(trashedPaths(unused), [gradleDistribution(version).path])
        }
        for (version, project) in [("9.7.0", "api"), ("9.8.2", "web")] {
            let wrapper = tmp.url("Dev/\(project)/gradle/wrapper/gradle-wrapper.properties").path
            XCTAssertEqual(try finding(.gradle, gradleDistribution(version).path, in: report).status, .pinned(by: [wrapper]), "case 9")
        }
        for major in [25, 26] {
            let jdk = try finding(.gradle, gradleJDK(major).path, in: report)
            XCTAssertEqual(jdk.status, .unused, "case 10: \(major)")
            XCTAssertEqual(jdk.reason, .unreferencedJDK(major: major))
            XCTAssertEqual(jdk.bucket, .needsDecision)
        }
        let systemJDK = try finding(.gradle, "\(ReferenceFileSystem.systemJDKDirectory)/temurin-27.jdk", in: report)
        XCTAssertEqual(systemJDK.reason, .systemJDK(major: 27), "case 10")
        XCTAssertEqual(systemJDK.bucket, .excluded)
        for folder in Self.oldIntelliJFolders {
            let leftover = try finding(.jetBrains, tmp.url("\(Self.jetBrainsConfigurations)/\(folder)").path, in: report)
            XCTAssertEqual(leftover.status, .unused, "case 11: \(folder)")
            XCTAssertEqual(leftover.bucket, .safe, "case 11: \(folder)")
            XCTAssertEqual(trashedPaths(leftover), [leftover.path.path])
        }
        let installed = tmp.url("\(Self.jetBrainsConfigurations)/IntelliJIdea2026.3").path
        XCTAssertFalse(report.findings.contains { $0.path.path == installed }, "case 11: the installed IDE's folder was reported")

        XCTAssertEqual(report.totals, CleanupTotals(safe: 11_111_111, needsDecision: 222))
        XCTAssertEqual(Set(report.findings.map(\.id)).count, report.findings.count, "finding ids are unique report-wide")
        XCTAssertEqual(
            report.findings.map(\.detector).reduce(into: [CleanupDetectorID]()) { if $0.last != $1 { $0.append($1) } },
            [.runtimeVersions, .gradle, .jetBrains]
        )
        XCTAssertEqual(report.notes, [])
        XCTAssertEqual(report.skippedProtected, [])
        XCTAssertEqual(trash.urls, [], "the scan never moves anything to the Trash")
        XCTAssertEqual(reference.mutations, [], "the scan never creates or moves anything")
        XCTAssertEqual(try treeListing(), before)
    }

    /// No link inside a project root is followed; a root that leads into a protected folder is
    /// refused and reported once, even when the `PATH` scan refused the same folder; no protected
    /// path ever reaches the file system under the guard.
    func testScanNeverTouchesAProtectedPathWithProjectRoots() async throws {
        let path = try buildReferenceTree()
        let hidden = try tmp.file("Documents/z", size: 16, executable: true)
        try tmp.symlink(".local/bin/z", to: hidden.path)
        try tmp.file("opt/homebrew/bin/z", size: 16, executable: true)
        try tmp.file("Dev/app/.nvmrc", text: "22\n")
        try tmp.file("Documents/code/.nvmrc", text: "20\n")
        try tmp.file("Desktop/site/package.json", text: "{}\n")
        try tmp.symlink("Dev/notes", to: tmp.url("Documents").path)
        try tmp.symlink("Dev/Desktop", to: tmp.url("Desktop").path)
        try tmp.symlink("Projects", to: tmp.url("Documents/code").path)

        let report = try await scan(context(path: path, space: SpaceSetup(projectRoots: ["Dev", "Projects"]))).get()

        XCTAssertEqual(report.skippedProtected, [tmp.url("Documents").path])
        XCTAssertTrue(recording.touched.contains(tmp.url("Dev/app/.nvmrc").path), "the walk never read ~/Dev")
        let roots = ProtectedLocationGuard.protectedRoots(home: tmp.home).map(CleanupPathText.components(of:))
        let offenders = recording.touched.filter { touched in
            roots.contains { CleanupPathText.components(of: touched).starts(with: $0) }
        }
        XCTAssertEqual(offenders, [], "the base file system received a protected path")
        XCTAssertFalse(report.notes.contains { $0.kind == .noProjectRoots }, "~/Dev was walked")
        XCTAssertEqual(trash.urls, [])
    }

    /// Review Focus 4: with no project root searched, the managers' own defaults still protect what
    /// they point to, no distribution can be proven unused, and a note says why.
    func testMissingProjectRootsLeaveANoteAndDowngradeDistributions() async throws {
        let link = try installUvPythons()
        try installDistribution("9.2.0")

        for roots in [[], ["Dev"]] {
            let report = try await scan(context(path: [], space: SpaceSetup(projectRoots: roots))).get()

            XCTAssertEqual(report.notes, [CleanupDetectorNote(detector: .runtimeVersions, kind: .noProjectRoots)], "roots \(roots)")
            XCTAssertEqual(try finding(.runtimeVersions, uvPython("3.15.2").path, in: report).status, .pinned(by: [link.path]))
            let oldPython = try finding(.runtimeVersions, uvPython("3.12.12").path, in: report)
            XCTAssertEqual(oldPython.status, .unused, "roots \(roots)")
            XCTAssertEqual(oldPython.bucket, .needsDecision)
            let distribution = try finding(.gradle, gradleDistribution("9.2.0").path, in: report)
            XCTAssertEqual(distribution.status, .unused, "roots \(roots)")
            XCTAssertEqual(distribution.bucket, .needsDecision, "roots \(roots)")
        }
    }

    /// A root the guard refuses may hold projects whose wrappers were never read, so even with
    /// another root walked completely no distribution is proven unused.
    func testARefusedProjectRootKeepsDistributionsUndecided() async throws {
        try installDistribution("9.2.0")
        try tmp.file("Dev/app/.nvmrc", text: "22\n")
        try tmp.file(
            "Documents/code/gradle/wrapper/gradle-wrapper.properties",
            text: "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.2.0-bin.zip\n"
        )
        try tmp.symlink("Work", to: tmp.url("Documents/code").path)

        let report = try await scan(context(path: [], space: SpaceSetup(projectRoots: ["Dev", "Work"]))).get()

        XCTAssertEqual(report.skippedProtected, [tmp.url("Documents").path])
        XCTAssertTrue(recording.touched.contains(tmp.url("Dev/app/.nvmrc").path), "precondition: ~/Dev was walked")
        let distribution = try finding(.gradle, gradleDistribution("9.2.0").path, in: report)
        XCTAssertEqual(distribution.status, .unused)
        XCTAssertEqual(distribution.bucket, .needsDecision)
        let roots = ProtectedLocationGuard.protectedRoots(home: tmp.home).map(CleanupPathText.components(of:))
        let offenders = recording.touched.filter { touched in
            roots.contains { CleanupPathText.components(of: touched).starts(with: $0) }
        }
        XCTAssertEqual(offenders, [], "the base file system received a protected path")
    }

    /// A project folder that cannot be listed may hold a wrapper the walk never saw; the folders
    /// that were read still count.
    func testAnUnreadableProjectFolderMakesEvidenceIncomplete() async throws {
        try installDistribution("9.2.0")
        try installDistribution("9.8.2")
        let web = try wrapper(project: "web", version: "9.8.2")
        try wrapper(project: "locked", version: "9.2.0")
        let locked = tmp.url("Dev/locked").path

        let failure = (path: locked, error: CleanupFileSystemError.io(locked) as Error)
        let report = try await scan(context(path: [], failure: failure)).get()

        XCTAssertEqual(report.notes, [CleanupDetectorNote(detector: .runtimeVersions, kind: .projectWalkTruncated)])
        let unseen = try finding(.gradle, gradleDistribution("9.2.0").path, in: report)
        XCTAssertEqual(unseen.status, .unused)
        XCTAssertEqual(unseen.bucket, .needsDecision)
        XCTAssertEqual(try finding(.gradle, gradleDistribution("9.8.2").path, in: report).status, .pinned(by: [web.path]))
    }

    func testCancellationDuringTheWalkThrows() async throws {
        let path = try buildReferenceTree()
        try tmp.file("Dev/api/.nvmrc", text: "22\n")
        try tmp.file("Dev/web/.nvmrc", text: "20\n")
        let laterDetectors = [
            ("D5", ".local/share/uv"), ("D6", ".gradle"), ("D7", Self.jetBrainsConfigurations),
            ("D8", ".local/state/fnm_multishells"),
        ]
        _ = try await scan(context(path: path)).get()
        for (detector, relative) in laterDetectors {
            XCTAssertTrue(recording.touched.contains(tmp.url(relative).path), "precondition: \(detector) reads \(relative)")
        }

        let result = await scan(context(path: path, space: SpaceSetup(cancelsWhenListing: "Dev")))

        guard case .failure(let error) = result else {
            return XCTFail("a scan cancelled during the walk returned a report")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        XCTAssertEqual(brew.dryRuns, ["cleanup", "autoremove", "cleanup", "autoremove"], "D4 runs before the walk")
        XCTAssertTrue(recording.touched.contains(tmp.url("Dev").path), "the task must be cancelled while listing ~/Dev")
        XCTAssertFalse(recording.touched.contains(tmp.url("Dev/api").path), "the walk went on after the cancellation")
        for (detector, relative) in laterDetectors {
            XCTAssertFalse(recording.touched.contains(tmp.url(relative).path), "\(detector) ran after the cancellation")
        }
    }

    /// Nested or linked roots list a file once per root; D5 and D6 get each physical path once, in
    /// the order the walk first found it.
    func testProjectFilesListedTwiceReachTheDetectorsOnce() {
        let file = { (path: String) in
            CleanupProjectFile(url: URL(filePath: path, directoryHint: .notDirectory), kind: .nvmrc, text: "22\n")
        }
        let web = file("/p/Dev/web/.nvmrc")
        let app = file("/p/Dev/app/.nvmrc")

        let unique = CleanupScanner.uniqueProjectFiles([web, app, file("/p/Dev/web/.nvmrc"), app])

        XCTAssertEqual(unique.map(\.url.path), [web.url.path, app.url.path])
    }

    // MARK: Stage 3 — PATH hygiene and the Files and Folders map

    private static let editorBundle = "com.example.editor"
    private static let pathClient = 1
    private static let bundleClient = 0
    private static let allowed = 2

    private var tccDatabase: URL { tmp.url("Library/Application Support/com.apple.TCC/TCC.db") }
    private var absentEntry: String { tmp.url("gone/bin").path }

    /// One app bundle allowed into the Documents folder.
    private func bundleMap() -> FakeTCCDatabase {
        FakeTCCDatabase(fileURL: tccDatabase, rows: [
            CleanupTCCRow(
                service: CleanupTCCService.documents.rawValue, client: Self.editorBundle,
                clientType: Self.bundleClient, authValue: Self.allowed
            ),
        ])
    }

    private func detectorSequence(_ report: CleanupReport) -> [CleanupDetectorID] {
        report.findings.map(\.detector).reduce(into: [CleanupDetectorID]()) { if $0.last != $1 { $0.append($1) } }
    }

    func testHygieneAndMapRunAfterShellState() async throws {
        let path = try buildReferenceTree() + [absentEntry]
        let map = bundleMap()

        let report = try await scan(context(path: path, tccMap: map)).get()

        XCTAssertEqual(detectorSequence(report), [.pathDuplicates, .versionDirectories, .shellState, .pathHygiene, .tccMap])
        let dead = try finding(.pathHygiene, absentEntry, in: report)
        XCTAssertEqual(dead.status, .deadEntry)
        XCTAssertEqual(dead.action, .instruction(.editShellFiles(entry: absentEntry, locations: [])))
        let entry = try XCTUnwrap(report.findings.first { $0.detector == .tccMap })
        XCTAssertEqual(entry.tool, Self.editorBundle)
        XCTAssertEqual(entry.action, .command("tccutil reset SystemPolicyDocumentsFolder \(Self.editorBundle)"))
        XCTAssertEqual(map.requestedServices, [CleanupTCCService.allCases], "D10 reads the database once")
        XCTAssertEqual(report.notes, [])
        XCTAssertEqual(Set(report.findings.map(\.id)).count, report.findings.count, "finding ids are unique report-wide")
    }

    /// A context without a database is the switch turned off: D10 leaves nothing, D9 still reports.
    func testMapOffBuildsNoD10Output() async throws {
        let path = try buildReferenceTree() + [absentEntry]

        let report = try await scan(context(path: path)).get()

        XCTAssertEqual(try finding(.pathHygiene, absentEntry, in: report).status, .deadEntry, "D9 does not depend on the map")
        XCTAssertFalse(report.findings.contains { $0.detector == .tccMap })
        XCTAssertEqual(report.notes, [], "no D10 note, and D9 adds none")
    }

    func testAThrowingMapLeavesAFailedNoteAndTheRestReports() async throws {
        let path = try buildReferenceTree() + [absentEntry]
        let map = FakeTCCDatabase(fileURL: tccDatabase, error: MapReaderFault())

        let report = try await scan(context(path: path, tccMap: map)).get()

        XCTAssertEqual(report.notes, [CleanupDetectorNote(detector: .tccMap, kind: .failed)])
        XCTAssertEqual(map.calls, 1, "precondition: D10 asked the database")
        XCTAssertFalse(report.findings.contains { $0.detector == .tccMap })
        XCTAssertEqual(try finding(.pathHygiene, absentEntry, in: report).status, .deadEntry)
        XCTAssertEqual(detectorSequence(report), [.pathDuplicates, .versionDirectories, .shellState, .pathHygiene])
    }

    /// A database D10 cannot read is its own note, not a failure, and the report keeps it.
    func testAnUnreadableMapLeavesItsOwnNote() async throws {
        let path = try buildReferenceTree()
        let map = FakeTCCDatabase(fileURL: tccDatabase, error: CleanupTCCDatabaseError.unreadable)

        let report = try await scan(context(path: path, tccMap: map)).get()

        XCTAssertEqual(report.notes, [CleanupDetectorNote(detector: .tccMap, kind: .tccUnreadable)])
        XCTAssertFalse(report.findings.contains { $0.detector == .tccMap })
    }

    func testCancellationBeforeTheMapThrows() async throws {
        let path = try buildReferenceTree()
        try tmp.directory("etc/paths.d")
        let map = bundleMap()

        let result = await scan(context(path: path, space: SpaceSetup(cancelsWhenListing: "etc/paths.d"), tccMap: map))

        guard case .failure(let error) = result else {
            return XCTFail("a scan cancelled while D9 listed paths.d returned a report")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        XCTAssertTrue(recording.touched.contains(tmp.url("etc/paths.d").path), "the task must be cancelled while D9 lists paths.d")
        XCTAssertEqual(map.calls, 0, "D10 read the database after the cancellation")
    }

    /// A `PATH` entry inside `~/Documents`, a `~/.zshrc` linked into it and a map entry for a tool in
    /// `~/Downloads`: each is refused and reported, and no protected path reaches the file system.
    func testScanNeverTouchesProtectedLocationsWithHygieneAndMap() async throws {
        var path = try buildReferenceTree()
        try tmp.file("Documents/bin/tool", size: 16, executable: true)
        let documentsBin = tmp.url("Documents/bin").path
        path.insert(documentsBin, at: 1)
        let shellFile = try tmp.file("Documents/dotfiles/zshrc", text: "export PATH=\"$HOME/Documents/bin:$PATH\"\n")
        try tmp.symlink(".zshrc", to: shellFile.path)
        let downloaded = try tmp.file("Downloads/tool", size: 16, executable: true)
        let map = FakeTCCDatabase(fileURL: tccDatabase, rows: [
            CleanupTCCRow(
                service: CleanupTCCService.downloads.rawValue, client: downloaded.path,
                clientType: Self.pathClient, authValue: Self.allowed
            ),
        ])

        let report = try await scan(context(path: path, tccMap: map)).get()

        XCTAssertTrue(recording.touched.contains(tmp.url(".zshrc").path), "precondition: D9 looked at ~/.zshrc")
        XCTAssertEqual(map.calls, 1, "precondition: D10 asked the database")
        XCTAssertEqual(report.skippedProtected, [documentsBin, tmp.url("Documents").path])
        let refusedClient = try finding(.tccMap, downloaded.path, in: report)
        XCTAssertEqual(refusedClient.status, .skippedProtected)
        XCTAssertEqual(refusedClient.reason, .protectedLocation)
        let roots = ProtectedLocationGuard.protectedRoots(home: tmp.home).map(CleanupPathText.components(of:))
        let offenders = recording.touched.filter { touched in
            roots.contains { CleanupPathText.components(of: touched).starts(with: $0) }
        }
        XCTAssertEqual(offenders, [], "the base file system received a protected path")
        XCTAssertEqual(trash.urls, [])
        XCTAssertEqual(reference.mutations, [])
    }
}
