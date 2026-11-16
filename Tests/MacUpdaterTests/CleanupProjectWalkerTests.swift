import XCTest
@testable import MacUpdaterCore

/// Lists like `base`, except that listing `path` throws `error`.
private struct FailingListingFileSystem: CleanupFileSystem {
    let base: CleanupFileSystem
    let path: String
    let error: Error

    func entry(at url: URL) throws -> CleanupEntry? { try base.entry(at: url) }

    func contents(of directory: URL) throws -> [CleanupEntry] {
        if ProtectedLocationGuard.standardizedPath(directory) == path { throw error }
        return try base.contents(of: directory)
    }

    func symlinkDestination(of url: URL) throws -> String { try base.symlinkDestination(of: url) }
    func realpath(_ url: URL) throws -> URL { try base.realpath(url) }
    func allocatedSize(of url: URL) throws -> Int64 { try base.allocatedSize(of: url) }
    func readText(_ url: URL, maxBytes: Int) throws -> String { try base.readText(url, maxBytes: maxBytes) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func moveItem(_ source: URL, to destination: URL) throws { try base.moveItem(source, to: destination) }
    func trash(_ url: URL) throws { try base.trash(url) }
}

final class CleanupProjectWalkerTests: XCTestCase {
    private var tmp: CleanupTempHome!
    private let live = LiveCleanupFileSystem(trash: { _ in })

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
    }

    private func kinds(_ walk: CleanupProjectWalk) -> [String: CleanupProjectFileKind] {
        Dictionary(walk.files.map { ($0.url.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    private func isPath(_ path: String, within root: URL) -> Bool {
        CleanupPathText.components(of: path).starts(with: CleanupPathText.components(of: root.path))
    }

    func testFindsEveryRequirementFileKindAndReadsItsText() throws {
        let root = try tmp.directory("Dev")
        let expected: [(relative: String, kind: CleanupProjectFileKind)] = [
            ("py/.python-version", .pythonVersion),
            ("node/.nvmrc", .nvmrc),
            ("node/.node-version", .nodeVersion),
            ("asdf/.tool-versions", .toolVersions),
            ("mise/mise.toml", .miseToml),
            ("mise/.mise.toml", .miseToml),
            ("py/pyproject.toml", .pyprojectToml),
            ("node/package.json", .packageJson),
            ("java/.sdkmanrc", .sdkmanrc),
            ("rust/rust-toolchain", .rustToolchain),
            ("rust/rust-toolchain.toml", .rustToolchainToml),
            ("app/gradle/wrapper/gradle-wrapper.properties", .gradleWrapperProperties),
            ("app/gradle/gradle-daemon-jvm.properties", .gradleDaemonJvmProperties),
            ("app/build.gradle.kts", .gradleBuildScript),
            ("app/settings.gradle.kts", .gradleBuildScript),
            ("legacy/build.gradle", .gradleBuildScript),
            ("legacy/settings.gradle", .gradleBuildScript),
            ("app/gradle/publishing.gradle", .gradleBuildScript),
            ("app/conventions/jvm.gradle.kts", .gradleBuildScript),
            ("app/buildSrc/src/main/kotlin/Conventions.kt", .gradleBuildScript),
            ("app/build-logic/convention/src/main/kotlin/JvmConventionPlugin.kt", .gradleBuildScript),
            ("py/.venv/pyvenv.cfg", .pyvenvCfg),
        ]
        for (index, file) in expected.enumerated() {
            try tmp.file("Dev/\(file.relative)", text: "content \(index) of \(file.relative)\n")
        }
        let ignored = [
            "app/src/main/kotlin/App.kt", "misc/gradle-wrapper.properties", "misc/wrapper/gradle-wrapper.properties",
            "misc/gradle-daemon-jvm.properties", "misc/pyvenv.cfg", "misc/README.md", "misc/requirements.txt",
        ]
        for relative in ignored {
            try tmp.file("Dev/\(relative)", text: "ignored\n")
        }

        let walk = try CleanupProjectWalker(fileSystem: live).walk(roots: [root])

        let expectedKinds = Dictionary(uniqueKeysWithValues: expected.map { (tmp.url("Dev/\($0.relative)").path, $0.kind) })
        XCTAssertEqual(kinds(walk), expectedKinds)
        XCTAssertEqual(walk.files.count, expected.count, "every file is read once")
        for (index, file) in expected.enumerated() {
            let found = walk.files.first { $0.url.path == tmp.url("Dev/\(file.relative)").path }
            XCTAssertEqual(found?.text, "content \(index) of \(file.relative)\n", file.relative)
        }
        XCTAssertEqual(walk.walkedRoots.map(\.path), [root.path])
        XCTAssertEqual(walk.missingRoots, [])
        XCTAssertEqual(walk.skippedProtected, [])
        XCTAssertTrue(walk.isComplete)
    }

    func testSkipListAndSymlinksAreNeverEntered() throws {
        let root = try tmp.directory("Dev")
        let read = try tmp.file("Dev/web/package.json", text: #"{"engines":{"node":">=20"}}"#)
        let skipped = [".git", "node_modules", "build", ".build", ".gradle", "target", "DerivedData", "Pods", "dist"]
        for name in skipped {
            try tmp.file("Dev/web/\(name)/x/package.json", text: "{}")
        }
        try tmp.file("Dev/app/build/tmp/gradle/wrapper/gradle-wrapper.properties", text: "distributionUrl=x\n")
        try tmp.file("Elsewhere/.nvmrc", text: "18\n")
        try tmp.symlink("Dev/link", to: "/")
        try tmp.symlink("Dev/elsewhere", to: "../Elsewhere")
        try tmp.symlink("Dev/web/.nvmrc", to: "../../Elsewhere/.nvmrc")
        let recording = RecordingCleanupFileSystem(wrapping: live)

        let walk = try CleanupProjectWalker(fileSystem: recording).walk(roots: [root])

        XCTAssertEqual(kinds(walk), [read.path: .packageJson])
        XCTAssertEqual(recording.touched.filter { !isPath($0, within: root) }, [], "the walk left the root")
        let neverEntered = skipped.map { tmp.url("Dev/web/\($0)") }
            + [tmp.url("Dev/app/build"), tmp.url("Dev/link"), tmp.url("Dev/elsewhere"), tmp.url("Dev/web/.nvmrc")]
        let entered = recording.touched.filter { touched in neverEntered.contains { isPath(touched, within: $0) } }
        XCTAssertEqual(entered, [], "a skipped directory or a symlink was entered")
        XCTAssertFalse(walk.truncated)
    }

    func testVenvIsEnteredOnlyForPyvenvCfg() throws {
        let root = try tmp.directory("Dev")
        let config = try tmp.file("Dev/py/.venv/pyvenv.cfg", text: "home = /opt/homebrew/opt/python@3.12/bin\n")
        try tmp.file("Dev/py/.venv/package.json", text: "{}")
        try tmp.file("Dev/py/.venv/.python-version", text: "3.11\n")
        try tmp.file("Dev/py/.venv/lib/python3.12/site-packages/x/package.json", text: "{}")
        let project = try tmp.file("Dev/py/pyproject.toml", text: "[project]\nrequires-python = \">=3.12\"\n")
        let recording = RecordingCleanupFileSystem(wrapping: live)

        let walk = try CleanupProjectWalker(fileSystem: recording).walk(roots: [root])

        XCTAssertEqual(kinds(walk), [config.path: .pyvenvCfg, project.path: .pyprojectToml])
        let venv = tmp.url("Dev/py/.venv")
        let insideVenv = Set(recording.touched.filter { isPath($0, within: venv) && $0 != venv.path })
        XCTAssertEqual(insideVenv, [config.path], "only pyvenv.cfg is touched inside .venv")
    }

    func testProtectedChildIsRecordedNotEntered() throws {
        try tmp.file("Documents/app/.nvmrc", text: "18\n")
        let readable = try tmp.file("Dev/app/.nvmrc", text: "20\n")
        try tmp.symlink("Dev/docs", to: tmp.url("Documents").path)
        let recording = RecordingCleanupFileSystem(wrapping: live)
        let guarded = GuardedCleanupFileSystem(
            base: recording, guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
        let protectedRoot = tmp.url("Downloads/project")

        let walk = try CleanupProjectWalker(fileSystem: guarded).walk(roots: [tmp.home, protectedRoot])

        XCTAssertEqual(walk.skippedProtected, [tmp.url("Documents").path, protectedRoot.path])
        XCTAssertEqual(kinds(walk), [readable.path: .nvmrc])
        XCTAssertTrue(recording.touched.contains(readable.path), "the recording file system was never reached")
        let roots = ProtectedLocationGuard.protectedRoots(home: tmp.home).map(CleanupPathText.components(of:))
        let offenders = recording.touched.filter { touched in
            roots.contains { CleanupPathText.components(of: touched).starts(with: $0) }
        }
        XCTAssertEqual(offenders, [], "the base file system received a protected path")
        XCTAssertEqual(recording.touched.filter { isPath($0, within: tmp.url("Dev/docs")) }, [], "the symlink was followed")
        XCTAssertEqual(walk.walkedRoots.map(\.path), [tmp.home.path])
        XCTAssertFalse(walk.truncated, "a refused path is reported, not missing evidence")
    }

    func testDepthAndCountCapsTruncate() throws {
        let root = try tmp.directory("Dev")
        let deepest = try tmp.file("Dev/1/2/3/4/5/6/7/.nvmrc", text: "20\n")
        try tmp.file("Dev/1/2/3/4/5/6/7/8/.python-version", text: "3.12\n")
        let recording = RecordingCleanupFileSystem(wrapping: live)

        let bounded = try CleanupProjectWalker(fileSystem: recording).walk(roots: [root])

        XCTAssertEqual(kinds(bounded), [deepest.path: .nvmrc], "8 levels below the root are read, the 9th is not")
        XCTAssertEqual(recording.touched.filter { isPath($0, within: tmp.url("Dev/1/2/3/4/5/6/7/8")) }, [])
        XCTAssertFalse(bounded.truncated, "the depth limit bounds the walk by design")

        let byDirectories = try CleanupProjectWalker(fileSystem: live, maxDirectories: 3).walk(roots: [root])

        XCTAssertTrue(byDirectories.truncated)
        XCTAssertFalse(byDirectories.isComplete)
        XCTAssertEqual(byDirectories.files, [])

        let first = try tmp.file("Dev/a.gradle", text: "")
        try tmp.file("Dev/b.gradle", text: "")

        let byFiles = try CleanupProjectWalker(fileSystem: live, maxFiles: 1).walk(roots: [root])

        XCTAssertTrue(byFiles.truncated)
        XCTAssertEqual(kinds(byFiles), [first.path: .gradleBuildScript])
    }

    func testSecretFilesAreNeverRead() throws {
        let root = try tmp.directory("Dev")
        let wrapper = try tmp.file(
            "Dev/app/gradle/wrapper/gradle-wrapper.properties",
            text: "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.8.2-bin.zip\n"
        )
        let secrets = try [
            tmp.file("Dev/app/gradle.properties", text: "signing.password=secret\n"),
            tmp.file("Dev/app/local.properties", text: "sdk.dir=/secret\n"),
            tmp.file("Dev/app/gradle/gradle.properties", text: "secret\n"),
            tmp.file("Dev/app/gradle/wrapper/gradle.properties", text: "secret\n"),
        ].map(\.path)
        let recording = RecordingCleanupFileSystem(wrapping: live)

        let walk = try CleanupProjectWalker(fileSystem: recording).walk(roots: [root])

        XCTAssertEqual(kinds(walk), [wrapper.path: .gradleWrapperProperties])
        XCTAssertEqual(recording.touched.filter(secrets.contains), [], "a secret file was passed to the file system")
    }

    func testMissingRootIsReported() throws {
        let root = try tmp.directory("Dev")
        let nvmrc = try tmp.file("Dev/.nvmrc", text: "20\n")
        let missing = tmp.url("Gone")
        let file = try tmp.file("NotAFolder", text: "")
        let link = try tmp.symlink("LinkedDev", to: root.path)
        let walker = CleanupProjectWalker(fileSystem: live)

        let walk = try walker.walk(roots: [missing, root, file, link])

        XCTAssertEqual(walk.missingRoots.map(\.path), [missing.path, file.path, link.path])
        XCTAssertEqual(walk.walkedRoots.map(\.path), [root.path])
        XCTAssertEqual(walk.files.map(\.url.path), [nvmrc.path], "a symlinked root is not followed")
        XCTAssertTrue(walk.isComplete)

        let nothing = try walker.walk(roots: [missing])

        XCTAssertEqual(nothing.missingRoots.map(\.path), [missing.path])
        XCTAssertFalse(nothing.truncated)
        XCTAssertFalse(nothing.isComplete, "no root was walked")
    }

    func testAnUnlistableDirectoryTruncatesTheWalkWhichGoesOn() throws {
        let root = try tmp.directory("Dev")
        try tmp.file("Dev/a/.nvmrc", text: "18\n")
        let later = try tmp.file("Dev/b/.nvmrc", text: "20\n")
        let failing = FailingListingFileSystem(
            base: live, path: tmp.url("Dev/a").path, error: CleanupFileSystemError.io("permission denied")
        )

        let walk = try CleanupProjectWalker(fileSystem: failing).walk(roots: [root])

        XCTAssertEqual(kinds(walk), [later.path: .nvmrc])
        XCTAssertEqual(walk.walkedRoots.map(\.path), [root.path])
        XCTAssertTrue(walk.truncated)
        XCTAssertFalse(walk.isComplete)
    }

    func testOversizedAndNonUTF8FilesAreSkipped() throws {
        let root = try tmp.directory("Dev")
        try tmp.file("Dev/big/.nvmrc", size: 262_145)
        let fits = try tmp.file("Dev/fits/.nvmrc", size: 262_144)
        let binary = try tmp.file("Dev/binary/.python-version")
        try Data([0xC3, 0x28]).write(to: binary)

        let walk = try CleanupProjectWalker(fileSystem: live).walk(roots: [root])

        XCTAssertEqual(kinds(walk), [fits.path: .nvmrc])
        XCTAssertFalse(walk.truncated, "a skipped file does not truncate the walk")
    }

    func testCancellationIsTheOnlyErrorTheWalkThrows() async throws {
        let root = try tmp.directory("Dev")
        try tmp.file("Dev/a/.nvmrc", text: "20\n")
        let walker = CleanupProjectWalker(fileSystem: live)

        let cancelled = await Task { () throws -> CleanupProjectWalk in
            withUnsafeCurrentTask { $0?.cancel() }
            return try walker.walk(roots: [root])
        }.result

        XCTAssertThrowsError(try cancelled.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }

        let failing = FailingListingFileSystem(base: live, path: tmp.url("Dev/a").path, error: CancellationError())

        XCTAssertThrowsError(try CleanupProjectWalker(fileSystem: failing).walk(roots: [root])) {
            XCTAssertTrue($0 is CancellationError, "a cancellation from the file system became \($0)")
        }
    }
}
