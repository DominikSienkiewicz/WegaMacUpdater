import Darwin
import XCTest
@testable import MacUpdaterCore

final class CleanupFileSystemTests: XCTestCase {
    private var temp: CleanupTempHome!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temp = try CleanupTempHome()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    private var home: URL { temp.home }

    private func locationGuard(mounts: [String] = ["/"]) -> ProtectedLocationGuard {
        ProtectedLocationGuard(home: home, mounts: FixedMountTable(mounts))
    }

    private func live(trash: RecordingTrash = RecordingTrash()) -> LiveCleanupFileSystem {
        LiveCleanupFileSystem(trash: trash.record)
    }

    private func guarded(trash: RecordingTrash = RecordingTrash()) -> GuardedCleanupFileSystem {
        GuardedCleanupFileSystem(base: live(trash: trash), guard: locationGuard())
    }

    private func guardedOverRecording(
        trash: RecordingTrash = RecordingTrash()
    ) -> (fileSystem: GuardedCleanupFileSystem, recording: RecordingCleanupFileSystem) {
        let recording = RecordingCleanupFileSystem(wrapping: live(trash: trash))
        return (GuardedCleanupFileSystem(base: recording, guard: locationGuard()), recording)
    }

    private func assertProtected<T>(
        _ expression: @autoclosure () throws -> T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            guard case CleanupFileSystemError.protectedLocation = error else {
                return XCTFail("expected .protectedLocation, got \(error) \(message)", file: file, line: line)
            }
        }
    }

    private func assertUntouched(
        _ recording: RecordingCleanupFileSystem,
        under directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prefix = directory.path
        // Scalars, not Characters: "/" followed by a combining mark is a single Character.
        let offenders = recording.touched.filter {
            $0 == prefix || $0.unicodeScalars.starts(with: (prefix + "/").unicodeScalars)
        }
        XCTAssertEqual(offenders, [], "the base file system received a path under \(prefix)", file: file, line: line)
    }

    /// A resolver over scripted primitives: `/dir` is a directory, `/dir/link` a link to
    /// `destination`, and every other path a file. Nothing touches the disk.
    private func scriptedResolver(linkDestination destination: String) -> CleanupPathResolver {
        CleanupPathResolver(
            check: { _ in },
            entry: { url in
                let kind: CleanupEntryKind = switch url.path {
                case "/dir": .directory
                case "/dir/link": .symlink
                default: .file
                }
                return CleanupEntry(
                    url: url, kind: kind, isExecutable: false,
                    identity: CleanupFileIdentity(device: 1, inode: 1), modificationDate: nil
                )
            },
            destination: { _ in destination }
        )
    }

    // MARK: Protected locations

    func testEveryProtectedRootIsRefused() {
        let expected = [
            "Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/Containers",
            "Library/Group Containers", "Library/Mail", "Library/Messages", "Library/Safari",
            "Library/CloudStorage",
        ].map { home.path + "/" + $0 } + ["/Volumes"]

        let roots = ProtectedLocationGuard.protectedRoots(home: home)

        XCTAssertEqual(roots.count, expected.count)
        XCTAssertEqual(Set(roots), Set(expected))
        let locationGuard = locationGuard()
        for root in expected {
            assertProtected(try locationGuard.check(URL(filePath: root)), root)
            assertProtected(try locationGuard.check(URL(filePath: root + "/a")), root + "/a")
        }
    }

    func testPrefixMatchesOnlyWholeComponents() {
        let locationGuard = locationGuard()

        XCTAssertNoThrow(try locationGuard.check(home.appending(path: "Documentsy/x")))
        XCTAssertNoThrow(try locationGuard.check(home.appending(path: "Library/Mailbox")))
        XCTAssertNoThrow(try locationGuard.check(home.appending(path: "Library")))
        assertProtected(try locationGuard.check(home.appending(path: "Library/Mail/x")))
        assertProtected(try locationGuard.check(home.appending(path: "Library/Caches/../Mail")))
    }

    func testCaseAndDataVolumeSpellingsOfAProtectedRootAreRefused() {
        let locationGuard = locationGuard(mounts: ["/", "/System/Volumes/Data"])

        assertProtected(try locationGuard.check(home.appending(path: "documents/x")))
        assertProtected(try locationGuard.check(home.appending(path: "LIBRARY/Mail")))
        assertProtected(try locationGuard.check(URL(filePath: "/volumes/USB")))
        assertProtected(try locationGuard.check(URL(filePath: "/System/Volumes/Data" + home.path + "/Desktop/x")))
        assertProtected(try locationGuard.check(URL(filePath: home.path + "/Documents/\u{301}y")), "combining mark")
        assertProtected(try locationGuard.check(URL(filePath: home.path + "/Download\u{17F}/x")), "long s")
        assertProtected(try locationGuard.check(URL(filePath: home.path + "/Documents\u{0}x")), "NUL")
    }

    func testACombiningMarkAfterASlashDoesNotHideAProtectedLocation() throws {
        try temp.directory("Documents")
        let hidden = home.path + "/Documents/\u{301}y"
        XCTAssertTrue(FileManager.default.createFile(atPath: hidden, contents: Data("secret".utf8)))
        let (fileSystem, recording) = guardedOverRecording()
        let url = URL(filePath: hidden, directoryHint: .notDirectory)

        assertProtected(try fileSystem.entry(at: url))
        assertProtected(try fileSystem.readText(url, maxBytes: 64))

        assertUntouched(recording, under: home.appending(path: "Documents"))
    }

    func testANulInThePathIsRefusedBeforeTheTrashIsReached() throws {
        try temp.directory("Documents")
        let trash = RecordingTrash()
        let (fileSystem, recording) = guardedOverRecording(trash: trash)

        assertProtected(try fileSystem.trash(URL(filePath: home.path + "/Documents\u{0}x", directoryHint: .notDirectory)))

        XCTAssertEqual(trash.urls, [])
        XCTAssertEqual(recording.touched, [])
    }

    func testPathsOnOtherMountsAreRefused() {
        let locationGuard = locationGuard(mounts: ["/", "/System/Volumes/Data", "/Volumes/USB", "/net/nas"])

        assertProtected(try locationGuard.check(URL(filePath: "/net/nas/x")))
        assertProtected(try locationGuard.check(URL(filePath: "/net/nas")))
        assertProtected(try locationGuard.check(URL(filePath: "/Volumes/USB/x")))
        XCTAssertNoThrow(try locationGuard.check(URL(filePath: "/opt/homebrew/bin/git")))
        XCTAssertNoThrow(try locationGuard.check(URL(filePath: "/System/Volumes/Data/opt/homebrew")))
        XCTAssertNoThrow(try locationGuard.check(URL(filePath: "/net/nasty/x")))
    }

    func testAnEmptyMountTableRefusesEverything() {
        assertProtected(try locationGuard(mounts: []).check(URL(filePath: "/opt/homebrew/bin/git")))
    }

    // MARK: Realpath

    func testRealpathRefusesASymlinkIntoAProtectedLocation() throws {
        try temp.file("Documents/x")
        try temp.file("Documents/y")
        let absolute = try temp.symlink(".local/bin/x", to: home.path + "/Documents/x")
        let relative = try temp.symlink(".local/bin/y", to: "../../Documents/y")
        let (fileSystem, recording) = guardedOverRecording()

        assertProtected(try fileSystem.realpath(absolute))
        assertProtected(try fileSystem.realpath(relative))

        XCTAssertFalse(recording.touched.isEmpty)
        assertUntouched(recording, under: home.appending(path: "Documents"))
    }

    func testRealpathResolvesEveryComponentLikeRealpath3() throws {
        let target = try temp.file("real/sub/tool")
        try temp.symlink("linked", to: "real")
        try temp.symlink("bin/tool", to: home.path + "/linked/sub/tool")
        try temp.symlink("bin/chain", to: "tool")
        try temp.symlink("bin/deep", to: "../real/sub")
        let inputs = ["bin/chain", "linked/sub/../sub/tool", "bin/deep/../sub/tool"].map { home.appending(path: $0) }

        for fileSystem in [live(), guarded()] as [CleanupFileSystem] {
            for input in inputs {
                XCTAssertEqual(try fileSystem.realpath(input).path, target.path, input.path)
            }
        }
        for input in inputs {
            let resolved = try XCTUnwrap(Darwin.realpath(input.path, nil))
            defer { free(resolved) }
            XCTAssertEqual(String(cString: resolved), target.path, "realpath(3) agrees for \(input.path)")
        }
    }

    func testRealpathDetectsALoop() throws {
        let start = try temp.symlink("a", to: "b")
        try temp.symlink("b", to: "a")

        for fileSystem in [live(), guarded()] as [CleanupFileSystem] {
            XCTAssertThrowsError(try fileSystem.realpath(start)) { error in
                XCTAssertEqual(error as? CleanupFileSystemError, .symlinkLoop(start.path))
            }
        }
    }

    func testRealpathFollowsAtMostFortyLinks() throws {
        let target = try temp.file("target")
        try temp.symlink("chain/40", to: target.path)
        for index in 0..<40 {
            try temp.symlink("chain/\(index)", to: "\(index + 1)")
        }

        XCTAssertEqual(try guarded().realpath(temp.url("chain/1")).path, target.path)
        XCTAssertThrowsError(try guarded().realpath(temp.url("chain/0"))) { error in
            XCTAssertEqual(error as? CleanupFileSystemError, .symlinkLoop(temp.url("chain/0").path))
        }
    }

    func testLinkDestinationsAreReadByScalarsNotCharacters() throws {
        let link = URL(filePath: "/dir/link", directoryHint: .notDirectory)

        XCTAssertEqual(try scriptedResolver(linkDestination: "/\u{301}x").resolve(link).path, "/\u{301}x")
        XCTAssertThrowsError(try scriptedResolver(linkDestination: "a\u{0}b").resolve(link)) { error in
            guard case CleanupFileSystemError.protectedLocation = error else {
                return XCTFail("expected .protectedLocation, got \(error)")
            }
        }
    }

    // MARK: Guarded operations

    func testOperationsBehindALinkIntoAProtectedLocationAreRefused() throws {
        let tool = try temp.file("Documents/bin/tool", size: 16)
        let own = try temp.file("own", size: 16)
        try temp.symlink("bin", to: "Documents/bin")
        let trash = RecordingTrash()
        let (fileSystem, recording) = guardedOverRecording(trash: trash)
        let through = home.appending(path: "bin/tool")

        XCTAssertEqual(try fileSystem.entry(at: home.appending(path: "bin"))?.kind, .symlink)
        assertProtected(try fileSystem.contents(of: home.appending(path: "bin")))
        assertProtected(try fileSystem.entry(at: through))
        assertProtected(try fileSystem.symlinkDestination(of: through))
        assertProtected(try fileSystem.allocatedSize(of: through))
        assertProtected(try fileSystem.readText(through, maxBytes: 64))
        assertProtected(try fileSystem.createDirectory(home.appending(path: "bin/new")))
        assertProtected(try fileSystem.moveItem(through, to: home.appending(path: "moved")))
        assertProtected(try fileSystem.moveItem(own, to: home.appending(path: "Documents/own")))
        assertProtected(try fileSystem.trash(through))

        assertUntouched(recording, under: home.appending(path: "Documents"))
        XCTAssertEqual(trash.urls, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tool.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
    }

    func testWholeTreeOperationsAboveAProtectedLocationAreRefused() throws {
        try temp.file("Documents/secret", size: 16)
        try temp.file("mnt/nas/share/file", size: 16)
        let trash = RecordingTrash()
        let recording = RecordingCleanupFileSystem(wrapping: live(trash: trash))
        let mounts = ["/", home.path + "/mnt/nas"]
        let fileSystem = GuardedCleanupFileSystem(base: recording, guard: locationGuard(mounts: mounts))

        assertProtected(try fileSystem.allocatedSize(of: home))
        assertProtected(try fileSystem.allocatedSize(of: home.appending(path: "Library")))
        assertProtected(try fileSystem.allocatedSize(of: home.appending(path: "mnt")))
        assertProtected(try fileSystem.entry(at: home.appending(path: "mnt/nas/share")))
        assertProtected(try fileSystem.trash(home.appending(path: "Library")))
        assertProtected(try fileSystem.moveItem(home.appending(path: "mnt"), to: home.appending(path: "elsewhere")))

        XCTAssertEqual(trash.urls, [])
        assertUntouched(recording, under: home.appending(path: "Documents"))
        assertUntouched(recording, under: home.appending(path: "Library"))
        assertUntouched(recording, under: home.appending(path: "mnt/nas"))
    }

    // MARK: Live adapter

    func testEntryDescribesTheItemItselfWithoutFollowingIt() throws {
        let tool = try temp.file("bin/tool", executable: true)
        let data = try temp.file("bin/data")
        let link = try temp.symlink("bin/link", to: "tool")
        let fileSystem = guarded()
        var status = stat()
        XCTAssertEqual(Darwin.lstat(tool.path, &status), 0)

        let toolEntry = try XCTUnwrap(fileSystem.entry(at: tool))
        let linkEntry = try XCTUnwrap(fileSystem.entry(at: link))

        XCTAssertEqual(toolEntry.kind, .file)
        XCTAssertTrue(toolEntry.isExecutable)
        XCTAssertNotNil(toolEntry.modificationDate)
        XCTAssertEqual(
            toolEntry.identity,
            CleanupFileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino))
        )
        XCTAssertEqual(try fileSystem.entry(at: data)?.isExecutable, false)
        XCTAssertEqual(linkEntry.kind, .symlink)
        XCTAssertNotEqual(linkEntry.identity, toolEntry.identity)
        XCTAssertEqual(try fileSystem.entry(at: home.appending(path: "bin"))?.kind, .directory)
        XCTAssertNil(try fileSystem.entry(at: home.appending(path: "bin/missing")))
        XCTAssertNil(try fileSystem.entry(at: home.appending(path: "missing/deeper")))
        XCTAssertEqual(
            try fileSystem.contents(of: home.appending(path: "bin")).map(\.url.lastPathComponent),
            ["data", "link", "tool"]
        )
        XCTAssertEqual(try fileSystem.symlinkDestination(of: link), "tool")
    }

    func testAllocatedSizeDoesNotFollowSymlinks() throws {
        let big = try temp.file("big", size: 1_048_576)
        let link = try temp.symlink("link", to: "big")
        let fileSystem = guarded()

        XCTAssertGreaterThanOrEqual(try fileSystem.allocatedSize(of: big), 1_048_576)
        XCTAssertLessThan(try fileSystem.allocatedSize(of: link), 4096)
    }

    func testDirectorySizeCountsItsFilesButNotWhatItsLinksPointAt() throws {
        try temp.file("outside/big", size: 1_048_576)
        try temp.file("dir/own", size: 1_048_576)
        try temp.symlink("dir/file-link", to: "../outside/big")
        try temp.symlink("dir/dir-link", to: "../outside")

        let size = try guarded().allocatedSize(of: home.appending(path: "dir"))

        XCTAssertGreaterThanOrEqual(size, 1_048_576)
        XCTAssertLessThan(size, 2 * 1_048_576)
    }

    func testReadTextDecodesSmallFilesAndRefusesLargerOnes() throws {
        let text = "/usr/local/bin\n/usr/bin\n"
        let file = try temp.file("etc/paths", text: text)
        let fileSystem = guarded()

        XCTAssertEqual(try fileSystem.readText(file, maxBytes: text.utf8.count), text)
        XCTAssertThrowsError(try fileSystem.readText(file, maxBytes: text.utf8.count - 1)) { error in
            guard case CleanupFileSystemError.io = error else { return XCTFail("expected .io, got \(error)") }
        }
    }

    func testCreateDirectoryAndMoveItemRearrangeInPlace() throws {
        let entry = try temp.file("state/81234_1762761600000", size: 16)
        let folder = home.appending(path: "state/cleanup")
        let fileSystem = guarded()

        try fileSystem.createDirectory(folder)
        try fileSystem.moveItem(entry, to: folder.appending(path: entry.lastPathComponent))

        XCTAssertNil(try fileSystem.entry(at: entry))
        XCTAssertEqual(try fileSystem.contents(of: folder).map(\.url.lastPathComponent), [entry.lastPathComponent])
    }

    func testTrashGoesThroughTheInjectedClosure() throws {
        let file = try temp.file("old/tool", size: 16)
        let trash = RecordingTrash()

        try guarded(trash: trash).trash(file)

        XCTAssertEqual(trash.urls, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        for name in ["CleanupFileSystem.swift", "CleanupProtectedLocations.swift"] {
            let source = try String(contentsOf: coreSource(name), encoding: .utf8)
            XCTAssertFalse(source.contains("removeItem("), "\(name) must not delete permanently")
        }
    }

    private func coreSource(_ name: String, file: String = #filePath) -> URL {
        URL(filePath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/MacUpdaterCore/\(name)")
    }
}
