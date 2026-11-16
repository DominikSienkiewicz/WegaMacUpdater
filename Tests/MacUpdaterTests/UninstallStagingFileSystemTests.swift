import Darwin
import Foundation
import Testing
import WegaHelperKit

/// The filesystem side of the helper verb that stages a root-owned application for the caller's
/// Trash: reading the target without following links, the staging root and its slots, the move,
/// and handing the moved tree to the caller.
///
/// In production these run as root on `/Applications` and the system staging root. Every one of
/// them also works unprivileged on paths the test owns, which is how the no-follow, same-volume
/// and hard-link guarantees are exercised here rather than only read off the source. Ownership is
/// handed to the test's own uid, so the tests observe each decision (handed over, hard-linked,
/// skipped, failed) rather than an owner change.
///
/// Every path is built under a `realpath`-resolved temporary directory: `/var` is itself a
/// symlink to `/private/var`, and the primitives refuse a symlink anywhere in a path.
@Suite("Uninstall staging on the filesystem")
struct UninstallStagingFileSystemTests {

    // MARK: - Reading the target

    @Test func inspectionDescribesTheEntryItselfNotWhereALinkPoints() throws {
        try withScratch { base in
            let bundle = try makeBundle(at: base + "/Apps/Foo.app", bundleID: "com.acme.foo")
            try FileManager.default.createSymbolicLink(atPath: base + "/Apps/Link.app", withDestinationPath: bundle)

            let real = try #require(UninstallStaging.inspectTarget(atPath: bundle))
            #expect(!real.isSymlink)
            #expect(real.ownerUID == getuid())
            #expect(real.resolvedPath == bundle)
            #expect(real.bundleID == "com.acme.foo")
            #expect(real.identity == real.identityAfterReading)
            #expect(real.identity == UninstallStaging.identity(atPath: bundle))

            let link = try #require(UninstallStaging.inspectTarget(atPath: base + "/Apps/Link.app"))
            #expect(link.isSymlink)
            #expect(link.identity != real.identity)
            #expect(link.resolvedPath == bundle)
            #expect(link.bundleID == nil, "the identifier is never read through a link")
        }
    }

    @Test func inspectionOfAMissingEntryIsNil() throws {
        try withScratch { base in
            #expect(UninstallStaging.inspectTarget(atPath: base + "/Apps/Gone.app") == nil)
        }
    }

    /// Ruling 16: a symlinked `Contents`, or a symlinked parent folder, would let the identifier
    /// come from a bundle other than the entry being moved.
    @Test func bundleIdentifierIsNeverReadThroughASymlink() throws {
        try withScratch { base in
            let elsewhere = try makeBundle(at: base + "/Elsewhere/Real.app", bundleID: "com.acme.real")
            try FileManager.default.createDirectory(atPath: base + "/Apps/Foo.app", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: base + "/Apps/Foo.app/Contents", withDestinationPath: elsewhere + "/Contents")
            #expect(UninstallStaging.bundleIdentifier(ofBundleAt: base + "/Apps/Foo.app") == nil)

            try FileManager.default.createSymbolicLink(atPath: base + "/Folder", withDestinationPath: base + "/Elsewhere")
            #expect(UninstallStaging.bundleIdentifier(ofBundleAt: base + "/Folder/Real.app") == nil)

            #expect(UninstallStaging.bundleIdentifier(ofBundleAt: elsewhere) == "com.acme.real")
        }
    }

    // MARK: - Staging root

    @Test func prepareRootCreatesASearchableSupportDirectoryAndARootOf0711() throws {
        try withScratch { base in
            let root = base + "/Support/UninstallStaging"

            #expect(UninstallStaging.prepareRoot(at: root, ownerUID: getuid()) == nil)
            let support = try permissions(of: base + "/Support")
            #expect(support & 0o022 == 0)
            #expect(support & 0o011 == 0o011)
            #expect(try permissions(of: root) == 0o711)
            #expect(UninstallStaging.prepareRoot(at: root, ownerUID: getuid()) == nil, "an existing root is accepted")
        }
    }

    /// `PackageStaging` creates Wega's support directory `0700`, which would lock every caller out
    /// of its own slot. Search is added; write for group or other never is, and is refused.
    @Test func prepareRootAddsSearchButNeverAcceptsWriteOnTheSupportDirectory() throws {
        try withScratch { base in
            try makeDirectory(base + "/Private", permissions: 0o700)
            #expect(UninstallStaging.prepareRoot(at: base + "/Private/UninstallStaging", ownerUID: getuid()) == nil)
            #expect(try permissions(of: base + "/Private") == 0o711)

            try makeDirectory(base + "/Shared", permissions: 0o775)
            #expect(UninstallStaging.prepareRoot(at: base + "/Shared/UninstallStaging", ownerUID: getuid())
                == .stagingRootUnsafe)
            #expect(!FileManager.default.fileExists(atPath: base + "/Shared/UninstallStaging"))
        }
    }

    @Test func prepareRootRefusesARootThatIsNotRootsAlone() throws {
        try withScratch { base in
            try makeDirectory(base + "/Support", permissions: 0o711)
            try makeDirectory(base + "/Support/Wide", permissions: 0o755)
            #expect(UninstallStaging.prepareRoot(at: base + "/Support/Wide", ownerUID: getuid()) == .stagingRootUnsafe)

            try makeDirectory(base + "/Support/Target", permissions: 0o711)
            try FileManager.default.createSymbolicLink(atPath: base + "/Support/Link", withDestinationPath: base + "/Support/Target")
            #expect(UninstallStaging.prepareRoot(at: base + "/Support/Link", ownerUID: getuid()) == .stagingRootUnsafe)

            try makeDirectory(base + "/Support/Mine", permissions: 0o711)
            #expect(UninstallStaging.prepareRoot(at: base + "/Support/Mine", ownerUID: getuid() + 1) == .stagingRootUnsafe)
        }
    }

    // MARK: - Slots

    @Test func aSlotIsAPrivateEmptyDirectoryNamedByAUUID() throws {
        try withScratch { base in
            let root = try preparedRoot(in: base)
            let slot = try #require(UninstallStaging.createSlot(in: root))

            let name = URL(fileURLWithPath: slot.path).lastPathComponent
            #expect(UUID(uuidString: name)?.uuidString == name)
            #expect(URL(fileURLWithPath: slot.path).deletingLastPathComponent().path == root)
            #expect(try permissions(of: slot.path) == 0o700)
            #expect(try FileManager.default.contentsOfDirectory(atPath: slot.path).isEmpty)
            #expect(UninstallStaging.identity(atPath: slot.path) == slot.identity)
        }
    }

    @Test func sweepingRemovesOnlyEmptySlotDirectories() throws {
        try withScratch { base in
            let root = try preparedRoot(in: base)
            let empty = try #require(UninstallStaging.createSlot(in: root))
            let occupied = try #require(UninstallStaging.createSlot(in: root))
            try Data("x".utf8).write(to: URL(fileURLWithPath: occupied.path + "/left.txt"))
            try makeDirectory(root + "/not-a-slot", permissions: 0o700)
            try makeDirectory(base + "/Elsewhere", permissions: 0o700)
            let linkName = UUID().uuidString
            try FileManager.default.createSymbolicLink(atPath: root + "/" + linkName, withDestinationPath: base + "/Elsewhere")

            #expect(UninstallStaging.sweepEmptySlots(in: root) == 1)
            #expect(!FileManager.default.fileExists(atPath: empty.path))
            #expect(FileManager.default.fileExists(atPath: occupied.path + "/left.txt"))
            #expect(FileManager.default.fileExists(atPath: root + "/not-a-slot"))
            #expect(FileManager.default.fileExists(atPath: base + "/Elsewhere"))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/" + linkName)) != nil)
        }
    }

    // MARK: - The move

    @Test func renameMovesThePlainBundleKeepingItsIdentity() throws {
        try withScratch { base in
            let bundle = try makeBundle(at: base + "/Apps/Utilities/Foo.app", bundleID: "com.acme.foo")
            let before = try #require(UninstallStaging.identity(atPath: bundle))
            let slot = try #require(UninstallStaging.createSlot(in: try preparedRoot(in: base)))

            let staged = try UninstallStaging.renameIntoSlot(bundle, slot: slot)

            #expect(staged == slot.path + "/Foo.app")
            #expect(UninstallStaging.identity(atPath: staged) == before)
            #expect(!FileManager.default.fileExists(atPath: bundle))
        }
    }

    /// Ruling 16: after validation, `<folder>` can be swapped for a link to somewhere else. The
    /// move refuses a symlink in any component instead of following it.
    @Test func renameRefusesASymlinkedParentFolder() throws {
        try withScratch { base in
            let bundle = try makeBundle(at: base + "/Elsewhere/Foo.app", bundleID: "com.acme.foo")
            try FileManager.default.createDirectory(atPath: base + "/Apps", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: base + "/Apps/Folder", withDestinationPath: base + "/Elsewhere")
            let slot = try #require(UninstallStaging.createSlot(in: try preparedRoot(in: base)))

            #expect(throws: (any Error).self) {
                try UninstallStaging.renameIntoSlot(base + "/Apps/Folder/Foo.app", slot: slot)
            }
            #expect(FileManager.default.fileExists(atPath: bundle))
            #expect(try FileManager.default.contentsOfDirectory(atPath: slot.path).isEmpty)
        }
    }

    @Test func discardingASlotRemovesItOnlyWhileEmpty() throws {
        try withScratch { base in
            let root = try preparedRoot(in: base)
            let slot = try #require(UninstallStaging.createSlot(in: root))
            #expect(UninstallStaging.discardSlot(slot))
            #expect(!FileManager.default.fileExists(atPath: slot.path))

            let kept = try #require(UninstallStaging.createSlot(in: root))
            try Data().write(to: URL(fileURLWithPath: kept.path + "/item"))
            #expect(!UninstallStaging.discardSlot(kept))
            #expect(FileManager.default.fileExists(atPath: kept.path + "/item"))
        }
    }

    // MARK: - Handing over the moved tree

    /// Ruling 13: a physical walk. The link is handed over as a link, nothing it points at is
    /// visited, a file with a second name elsewhere stays root's, and what is neither a file, a
    /// directory nor a link is left alone.
    @Test func handOverWalksTheTreeWithoutLeavingItOrTouchingHardLinkedFiles() throws {
        try withScratch { base in
            let bundle = try makeBundle(at: base + "/Slot/Foo.app", bundleID: "com.acme.foo")
            try makeDirectory(base + "/Outside", permissions: 0o755)
            try Data("secret".utf8).write(to: URL(fileURLWithPath: base + "/Outside/secret"))
            try FileManager.default.createSymbolicLink(
                atPath: bundle + "/Contents/Outside", withDestinationPath: base + "/Outside")
            try Data("shared".utf8).write(to: URL(fileURLWithPath: bundle + "/Contents/linked"))
            #expect(link(bundle + "/Contents/linked", base + "/Outside/second-name") == 0)
            #expect(mkfifo(bundle + "/Contents/pipe", 0o600) == 0)
            let expected = try #require(UninstallStaging.identity(atPath: bundle))

            let report = UninstallStaging.handOverTree(at: bundle, expected: expected, toUID: getuid(), gid: getgid())

            // Foo.app, Contents, Contents/Info.plist and the Contents/Outside link itself.
            #expect(report.handedOver == 4)
            #expect(report.hardLinked == [bundle + "/Contents/linked"])
            #expect(report.skipped == [bundle + "/Contents/pipe"])
            #expect(report.failed.isEmpty)
            #expect(!report.isComplete)
            #expect(report.leftWithRoot == 2)
        }
    }

    @Test func handOverOfAnOrdinaryBundleIsComplete() throws {
        try withScratch { base in
            let bundle = try makeBundle(at: base + "/Slot/Foo.app", bundleID: "com.acme.foo")
            try makeDirectory(bundle + "/Contents/MacOS", permissions: 0o755)
            try Data().write(to: URL(fileURLWithPath: bundle + "/Contents/MacOS/Foo"))
            let expected = try #require(UninstallStaging.identity(atPath: bundle))

            let report = UninstallStaging.handOverTree(at: bundle, expected: expected, toUID: getuid(), gid: getgid())

            #expect(report.handedOver == 5)
            #expect(report.isComplete)
            #expect(report.leftWithRoot == 0)
        }
    }

    /// The walk starts only from the entry that was validated: anything else in its place is
    /// refused before a single owner changes.
    @Test func handOverRefusesATreeThatIsNotTheValidatedBundle() throws {
        try withScratch { base in
            let bundle = try makeBundle(at: base + "/Slot/Foo.app", bundleID: "com.acme.foo")
            let other = try makeBundle(at: base + "/Other.app", bundleID: "com.acme.other")
            let wrong = try #require(UninstallStaging.identity(atPath: other))

            let report = UninstallStaging.handOverTree(at: bundle, expected: wrong, toUID: getuid(), gid: getgid())

            #expect(report.handedOver == 0)
            #expect(report.failed == [bundle])
        }
    }

    @Test func aSlotIsHandedOverOnlyWhileItIsTheOneCreated() throws {
        try withScratch { base in
            let root = try preparedRoot(in: base)
            let slot = try #require(UninstallStaging.createSlot(in: root))
            #expect(UninstallStaging.handOverSlot(slot, toUID: getuid(), gid: getgid()))

            let swapped = try #require(UninstallStaging.createSlot(in: root))
            try FileManager.default.removeItem(atPath: swapped.path)
            try makeDirectory(swapped.path, permissions: 0o700)
            #expect(!UninstallStaging.handOverSlot(swapped, toUID: getuid(), gid: getgid()))
        }
    }

    // MARK: - Fixture

    private func withScratch(_ body: (String) throws -> Void) throws {
        let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let base = String(cString: temporary) + "/wega-staging-\(UUID().uuidString)"
        try makeDirectory(base, permissions: 0o755)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try body(base)
    }

    private func preparedRoot(in base: String) throws -> String {
        let root = base + "/Support/UninstallStaging"
        try #require(UninstallStaging.prepareRoot(at: root, ownerUID: getuid()) == nil)
        return root
    }

    @discardableResult
    private func makeBundle(at path: String, bundleID: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return path
    }

    private func makeDirectory(_ path: String, permissions: mode_t) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #expect(chmod(path, permissions) == 0)
    }

    private func permissions(of path: String) throws -> mode_t {
        var status = stat()
        try #require(lstat(path, &status) == 0)
        return status.st_mode & 0o7777
    }
}
