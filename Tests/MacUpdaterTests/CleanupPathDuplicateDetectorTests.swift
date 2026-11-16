import XCTest
@testable import MacUpdaterCore

final class CleanupPathDuplicateDetectorTests: XCTestCase {
    private var tmp: CleanupTempHome!
    private var recording: RecordingCleanupFileSystem!
    private var brew: URL!

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        brew = tmp.url("opt/homebrew")
        recording = RecordingCleanupFileSystem(wrapping: LiveCleanupFileSystem(trash: { _ in }))
    }

    private func scan(_ directories: [String], systemPrefixes: [String]? = nil) -> CleanupPathScan {
        let guarded = GuardedCleanupFileSystem(
            base: recording,
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
        let classifier = systemPrefixes.map {
            CleanupSourceClassifier(home: tmp.home, brewPrefix: brew, systemPrefixes: $0)
        } ?? CleanupSourceClassifier(home: tmp.home, brewPrefix: brew)
        let snapshot = CleanupPathSnapshot(
            entries: directories, ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: false
        )
        return CleanupPathDuplicateDetector(fileSystem: guarded, classifier: classifier).scan(snapshot)
    }

    private func group(_ name: String, in scan: CleanupPathScan, file: StaticString = #filePath, line: UInt = #line) -> CleanupToolGroup? {
        let found = scan.groups.first { $0.name == name }
        XCTAssertNotNil(found, "group \(name) missing", file: file, line: line)
        return found
    }

    func testCaskCopyShadowedByNativeInstallIsReported() throws {
        let native = try tmp.file(".local/share/claude/versions/2.1.325", executable: true)
        let cask = try tmp.file("opt/homebrew/Caskroom/claude-code/2.1.311/claude", executable: true)
        try tmp.symlink(".local/bin/claude", to: native.path)
        try tmp.symlink("opt/homebrew/bin/claude", to: cask.path)

        let result = scan([tmp.url(".local/bin").path, tmp.url("opt/homebrew/bin").path])

        let claude = try XCTUnwrap(group("claude", in: result))
        XCTAssertEqual(claude.copies.map(\.role), [.active, .shadowed])
        XCTAssertEqual(claude.copies.map(\.pathIndex), [0, 1])
        XCTAssertEqual(claude.copies[0].source, .nativeVersionDirectory(tool: "claude"))
        XCTAssertEqual(claude.copies[0].version, "2.1.325")
        XCTAssertEqual(claude.copies[1].source, .homebrewCask(token: "claude-code"))
        XCTAssertEqual(claude.copies[1].version, "2.1.311")
        XCTAssertEqual(claude.copies[1].realpath, cask)
    }

    func testStandaloneFileWinsOverHomebrewFormula() throws {
        try tmp.file(".local/bin/gh", executable: true)
        let formula = try tmp.file("opt/homebrew/Cellar/gh/2.104.0/bin/gh", executable: true)
        try tmp.symlink("opt/homebrew/bin/gh", to: formula.path)

        let result = scan([tmp.url(".local/bin").path, tmp.url("opt/homebrew/bin").path])

        let gh = try XCTUnwrap(group("gh", in: result))
        XCTAssertEqual(gh.copies.map(\.role), [.active, .shadowed])
        XCTAssertEqual(gh.copies[0].source, .standalone)
        XCTAssertNil(gh.copies[0].version)
        XCTAssertEqual(gh.copies[1].source, .homebrewFormula(name: "gh"))
        XCTAssertEqual(gh.copies[1].version, "2.104.0")
    }

    func testHomebrewWinsOverAppProvidedLink() throws {
        let formula = try tmp.file("opt/homebrew/Cellar/ollama/0.9.0/bin/ollama", executable: true)
        let app = try tmp.file("Applications/Ollama.app/Contents/Resources/ollama", executable: true)
        try tmp.symlink("opt/homebrew/bin/ollama", to: formula.path)
        try tmp.symlink("usr/local/bin/ollama", to: app.path)

        let result = scan([tmp.url("opt/homebrew/bin").path, tmp.url("usr/local/bin").path])

        let ollama = try XCTUnwrap(group("ollama", in: result))
        XCTAssertEqual(ollama.copies.map(\.role), [.active, .shadowed])
        XCTAssertEqual(ollama.copies[0].source, .homebrewFormula(name: "ollama"))
        XCTAssertEqual(ollama.copies[1].source, .appBundle(name: "Ollama"))
    }

    func testSystemCopiesAreExpected() throws {
        let formula = try tmp.file("opt/homebrew/Cellar/git/2.50.0/bin/git", executable: true)
        try tmp.symlink("opt/homebrew/bin/git", to: formula.path)
        try tmp.file("usr/bin/git", executable: true)

        let result = scan(
            [tmp.url("opt/homebrew/bin").path, tmp.url("usr/bin").path],
            systemPrefixes: [tmp.url("usr/bin").path]
        )

        let git = try XCTUnwrap(group("git", in: result))
        XCTAssertEqual(git.copies.map(\.role), [.active, .expected])
        XCTAssertEqual(git.copies[1].source, .system)
    }

    func testSameRealpathIsNotADuplicate() throws {
        let target = try tmp.file("opt/tool/real", executable: true)
        try tmp.symlink("a/bin/tool", to: target.path)
        try tmp.symlink("b/bin/tool", to: target.path)

        let result = scan([tmp.url("a/bin").path, tmp.url("b/bin").path])

        XCTAssertEqual(result.groups, [])
    }

    func testProtectedPathEntryIsSkippedUntouched() throws {
        try tmp.file("Documents/bin/secret", executable: true)
        let documentsBin = tmp.url("Documents/bin").path

        let result = scan([documentsBin, tmp.url("opt/homebrew/bin").path])

        XCTAssertEqual(result.skippedProtected, [documentsBin])
        let documents = tmp.url("Documents").path
        let offenders = recording.touched.filter {
            $0 == documents || $0.unicodeScalars.starts(with: (documents + "/").unicodeScalars)
        }
        XCTAssertEqual(offenders, [], "the base file system received a path under ~/Documents")
    }

    func testMissingDirectoryIsReported() throws {
        let missing = tmp.url("nowhere/bin").path
        XCTAssertEqual(scan([missing]).missingDirectories, [missing])
    }

    func testDanglingAndLoopingLinksAreBrokenNotFatal() throws {
        let real = try tmp.file("opt/real/tool", executable: true)
        try tmp.file("a/bin/tool", executable: true)
        try tmp.symlink("b/bin/tool", to: real.path)
        try tmp.symlink("c/bin/dangling", to: tmp.url("opt/gone").path)
        try tmp.symlink("d/bin/dangling", to: tmp.url("opt/real/tool").path)
        try tmp.symlink("c/bin/loop", to: tmp.url("c/bin/loop2").path)
        try tmp.symlink("c/bin/loop2", to: tmp.url("c/bin/loop").path)
        try tmp.file("d/bin/loop", executable: true)

        let result = scan(["a", "b", "c", "d"].map { tmp.url("\($0)/bin").path })

        XCTAssertEqual(try XCTUnwrap(group("tool", in: result)).copies.map(\.role), [.active, .shadowed])
        let dangling = try XCTUnwrap(group("dangling", in: result))
        XCTAssertEqual(dangling.copies.map(\.role), [.brokenLink, .active])
        XCTAssertNil(dangling.copies[0].realpath)
        XCTAssertNil(dangling.copies[0].version)
        let loop = try XCTUnwrap(group("loop", in: result))
        XCTAssertEqual(loop.copies.map(\.role), [.brokenLink, .active])
    }

    func testLinkIntoProtectedLocationIsBrokenAndReported() throws {
        let hidden = try tmp.file("Documents/tools/tool", executable: true)
        try tmp.file("a/bin/tool", executable: true)
        try tmp.symlink("b/bin/tool", to: hidden.path)

        let result = scan([tmp.url("a/bin").path, tmp.url("b/bin").path])

        let tool = try XCTUnwrap(group("tool", in: result))
        XCTAssertEqual(tool.copies.map(\.role), [.active, .brokenLink])
        XCTAssertEqual(result.skippedProtected, [tmp.url("Documents").path], "the guard names the protected root it refused")
    }

    func testNonExecutableAndDirectoryChildrenAreIgnored() throws {
        try tmp.file("a/bin/tool", executable: true)
        try tmp.file("b/bin/tool", executable: false)
        try tmp.directory("c/bin/tool")

        XCTAssertEqual(scan(["a", "b", "c"].map { tmp.url("\($0)/bin").path }).groups, [])
    }
}
