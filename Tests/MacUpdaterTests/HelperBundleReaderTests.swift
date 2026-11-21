import Darwin
import Foundation
import Testing
import WegaHelperKit

/// RC4 of the design review: the live reader proves each entry through descriptors — `lstat` (or
/// `fstatat` in the folder's descriptor) without following a link, then the same device and inode
/// through the opened descriptor, then the ACL from that descriptor, where only `ENOENT` means none.
/// Runs the real system calls over temporary layouts owned by the test's user.
@Suite("Helper bundle reader")
struct HelperBundleReaderTests {

    @Test func aCompleteLayoutReadsEveryEntryWithItsKindOwnerModeAndNoACL() throws {
        let layout = try Layout()
        let reader = HelperBundleReader(bundlePath: layout.bundle)

        for entry in HelperBundleEntry.allCases {
            let facts = try #require(reader.facts(of: entry), "\(entry)")
            #expect(facts.kind == (entry.isDirectory ? .directory : .regularFile), "\(entry)")
            #expect(facts.ownerUID == getuid(), "\(entry)")
            #expect(facts.permissions == (entry.isDirectory ? 0o755 : 0o644), "\(entry)")
            #expect(facts.accessControl == .absent, "\(entry)")
        }
    }

    @Test func theModeIsReadAsItIs() throws {
        let layout = try Layout()
        try layout.chmod(.macOS, 0o775)
        try layout.chmod(.launchdPlist, 0o666)
        let reader = HelperBundleReader(bundlePath: layout.bundle)

        _ = reader.facts(of: .bundle)
        _ = reader.facts(of: .contents)
        #expect(reader.facts(of: .macOS)?.permissions == 0o775)
        _ = reader.facts(of: .library)
        _ = reader.facts(of: .launchDaemons)
        #expect(reader.facts(of: .launchdPlist)?.permissions == 0o666)
    }

    @Test(arguments: [HelperBundleEntry.bundle, .contents, .launchDaemons, .helperExecutable])
    func anACLIsSeenOnFoldersAndFiles(entry: HelperBundleEntry) throws {
        let layout = try Layout()
        try layout.addACL(to: entry)
        let reader = HelperBundleReader(bundlePath: layout.bundle)

        let facts = Self.read(entry, with: reader)

        #expect(facts?.accessControl == .present)
    }

    /// A link is reported as a link and never followed: what it points to is a sound folder here,
    /// and nothing below the link is read.
    @Test func aLinkedFolderIsALinkAndNothingBelowItIsRead() throws {
        let layout = try Layout()
        let real = layout.root + "/RealContents"
        try FileManager.default.moveItem(atPath: layout.path(of: .contents), toPath: real)
        try FileManager.default.createSymbolicLink(atPath: layout.path(of: .contents), withDestinationPath: real)
        let reader = HelperBundleReader(bundlePath: layout.bundle)

        _ = reader.facts(of: .bundle)
        #expect(reader.facts(of: .contents)?.kind == .symbolicLink)
        #expect(reader.facts(of: .macOS) == nil, "no descriptor is kept for a link")
        #expect(reader.facts(of: .helperExecutable) == nil)
    }

    @Test func aLinkedBundleIsALink() throws {
        let layout = try Layout()
        let link = layout.root + "/Linked.app"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: layout.bundle)
        let reader = HelperBundleReader(bundlePath: link)

        #expect(reader.facts(of: .bundle)?.kind == .symbolicLink)
        #expect(reader.facts(of: .contents) == nil)
    }

    /// The bundle is opened with `O_NOFOLLOW_ANY`: a link anywhere above it fails the open.
    @Test func aLinkAboveTheBundleMakesItUnreadable() throws {
        let layout = try Layout()
        let linkedRoot = layout.root + "-link"
        try FileManager.default.createSymbolicLink(atPath: linkedRoot, withDestinationPath: layout.root)
        defer { try? FileManager.default.removeItem(atPath: linkedRoot) }
        let reader = HelperBundleReader(bundlePath: linkedRoot + "/WegaMacUpdater.app")

        #expect(reader.facts(of: .bundle) == nil)
    }

    @Test func aLinkedHelperIsALink() throws {
        let layout = try Layout()
        try FileManager.default.removeItem(atPath: layout.path(of: .helperExecutable))
        try FileManager.default.createSymbolicLink(atPath: layout.path(of: .helperExecutable), withDestinationPath: "/usr/bin/true")
        let reader = HelperBundleReader(bundlePath: layout.bundle)

        #expect(Self.read(.helperExecutable, with: reader)?.kind == .symbolicLink)
    }

    /// A FIFO is reported without being opened, so the reader never blocks on it.
    @Test func aFIFOIsAnotherKindAndIsNotOpened() throws {
        let layout = try Layout()
        try FileManager.default.removeItem(atPath: layout.path(of: .helperExecutable))
        guard mkfifo(layout.path(of: .helperExecutable), 0o644) == 0 else { throw POSIXError(.EIO) }
        let reader = HelperBundleReader(bundlePath: layout.bundle)

        #expect(Self.read(.helperExecutable, with: reader)?.kind == .other)
    }

    @Test(arguments: HelperBundleEntry.allCases)
    func aMissingEntryHasNoFacts(entry: HelperBundleEntry) throws {
        let layout = try Layout()
        try FileManager.default.removeItem(atPath: layout.path(of: entry))
        let reader = HelperBundleReader(bundlePath: layout.bundle)

        #expect(Self.read(entry, with: reader) == nil)
    }

    /// A file the reader may not open has no facts: its ACL cannot be read through a descriptor.
    @Test func aFileTheReaderCannotOpenHasNoFacts() throws {
        let layout = try Layout()
        try layout.chmod(.launchdPlist, 0o000)
        let reader = HelperBundleReader(bundlePath: layout.bundle)

        #expect(Self.read(.launchdPlist, with: reader) == nil)
    }

    /// Through the gate, a layout the test's user owns is refused at the bundle, and a layout outside
    /// `/Applications` is refused before anything is read.
    @Test func theLiveGateRefusesAUserOwnedBundleAndAnyOtherLocation() throws {
        let layout = try Layout()
        let reader = HelperBundleReader(bundlePath: layout.bundle)

        #expect(HelperBundleGate.trust(bundlePath: "/Applications/WegaMacUpdater.app", facts: reader.facts(of:))
            == .refused(.notOwnedByRoot(.bundle)))
        #expect(HelperBundleGate.live(bundlePath: layout.bundle) == .refused(.notInApplications))
    }

    /// A system bundle shows what root ownership reads as: owner 0, no write for group or others.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Applications/Calculator.app/Contents/MacOS")))
    func aSystemBundleReadsAsRootOwned() throws {
        let reader = HelperBundleReader(bundlePath: "/System/Applications/Calculator.app")

        for entry in [HelperBundleEntry.bundle, .contents, .macOS] {
            let facts = try #require(reader.facts(of: entry), "\(entry)")
            #expect(facts.kind == .directory)
            #expect(facts.ownerUID == 0)
            #expect(facts.permissions & 0o022 == 0)
        }
        #expect(reader.facts(of: .helperExecutable) == nil)
    }

    // MARK: - The volume

    @Test func aLayoutOnTheDeviceOfApplicationsReadsAsOnItsVolume() throws {
        let layout = try Layout()
        let reader = HelperBundleReader(bundlePath: layout.bundle, volumeProbe: Self.probe(applicationsDevice: layout.device))

        for entry in HelperBundleEntry.allCases {
            #expect(reader.facts(of: entry)?.volume == .applications, "\(entry)")
        }
    }

    /// Note 6 of the Z14 security review: a file system mounted at the bundle or inside it is on
    /// another device. No test can mount one, so the probe puts `/Applications` on another device
    /// instead, and every entry, read through its folders, is then on another volume.
    @Test(arguments: HelperBundleEntry.allCases)
    func anEntryOnAnotherDeviceThanApplicationsIsOnAnotherVolume(entry: HelperBundleEntry) throws {
        let layout = try Layout()
        let reader = HelperBundleReader(bundlePath: layout.bundle, volumeProbe: Self.probe(applicationsDevice: layout.device &+ 1))

        #expect(Self.read(entry, with: reader)?.volume == .other)
    }

    /// The flags come from `fstatfs` on the bundle's own descriptor: the stand-in reports a volume
    /// that ignores ownership only for a descriptor of the bundle.
    @Test func aBundleOnAVolumeThatIgnoresOwnershipReadsAsSuch() throws {
        let layout = try Layout()
        let bundleInode = try layout.inode(of: .bundle)
        let reader = HelperBundleReader(bundlePath: layout.bundle, volumeProbe: Self.probe(applicationsDevice: layout.device) { descriptor in
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_ino == bundleInode else { return 0 }
            return UInt32(MNT_IGNORE_OWNERSHIP)
        })

        #expect(reader.facts(of: .bundle)?.volume == .ignoresOwnership)
    }

    /// Nothing proves the volume without the device of `/Applications` or the bundle's flags, so the
    /// bundle has no facts and nothing below it is read.
    @Test func withoutTheVolumeFactsTheBundleHasNoFacts() throws {
        let layout = try Layout()
        let device = layout.device
        let readers = [
            HelperBundleReader(bundlePath: layout.bundle, volumeProbe: HelperBundleVolumeProbe(applicationsDevice: { nil }, mountFlags: { _ in 0 })),
            HelperBundleReader(bundlePath: layout.bundle, volumeProbe: HelperBundleVolumeProbe(applicationsDevice: { device }, mountFlags: { _ in nil })),
        ]

        for reader in readers {
            #expect(reader.facts(of: .bundle) == nil)
            #expect(reader.facts(of: .contents) == nil)
        }
    }

    @Test func theLiveProbeReadsTheDeviceOfApplicationsAndTheFlagsOfADescriptor() throws {
        var applications = stat()
        #expect(lstat("/Applications", &applications) == 0)
        #expect(HelperBundleVolumeProbe.live.applicationsDevice() == applications.st_dev)
        let layout = try Layout()
        let descriptor = open(layout.bundle, O_RDONLY | O_DIRECTORY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        let flags = try #require(HelperBundleVolumeProbe.live.mountFlags(descriptor))

        #expect(flags & UInt32(MNT_LOCAL) != 0, "the flags of the temporary folder's local volume")
        #expect(flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0)
    }

    /// The genuine pkg install, where this Mac has one: on the volume of `/Applications`, owners
    /// honoured, so the volume check refuses nothing a root-owned install is.
    @Test(.enabled(if: HelperBundleReaderTests.aRootOwnedInstallIsPresent))
    func aRootOwnedInstallInApplicationsIsTrusted() {
        #expect(HelperBundleGate.live(bundlePath: Self.installedBundle) == .trusted)
    }

    // MARK: - Helpers

    private static let installedBundle = "/Applications/WegaMacUpdater.app"

    static var aRootOwnedInstallIsPresent: Bool {
        var status = stat()
        return lstat(installedBundle, &status) == 0 && status.st_uid == 0
            && FileManager.default.fileExists(atPath: installedBundle + "/" + HelperBundleEntry.launchdPlist.relativePath)
    }

    /// `/Applications` on `applicationsDevice`, and the flags `mountFlags` reports for a descriptor:
    /// none by default, a volume that honours ownership.
    private static func probe(
        applicationsDevice: dev_t, mountFlags: @escaping @Sendable (Int32) -> UInt32? = { _ in 0 }
    ) -> HelperBundleVolumeProbe {
        HelperBundleVolumeProbe(applicationsDevice: { applicationsDevice }, mountFlags: mountFlags)
    }

    /// Reads every folder above `entry` first, as the gate does, then `entry`.
    private static func read(_ entry: HelperBundleEntry, with reader: HelperBundleReader) -> HelperBundleEntryFacts? {
        var chain: [HelperBundleEntry] = []
        var current: HelperBundleEntry? = entry
        while let step = current {
            chain.insert(step, at: 0)
            current = step.parent
        }
        var last: HelperBundleEntryFacts?
        for step in chain { last = reader.facts(of: step) }
        return last
    }

    /// A bundle layout in a fresh temporary folder: folders 0755, files 0644. Removed with the layout.
    private final class Layout {
        let root: String
        let bundle: String

        init() throws {
            // Resolved with `realpath`, because the temporary folder lies under `/var`, a link to
            // `/private/var`, the reader opens the bundle with `O_NOFOLLOW_ANY`, and Foundation's
            // `resolvingSymlinksInPath` drops the `/private` again.
            guard let temporary = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw POSIXError(.EIO) }
            defer { free(temporary) }
            root = String(cString: temporary) + "/wega-bundle-reader-\(UUID().uuidString)"
            bundle = root + "/WegaMacUpdater.app"
            for entry in HelperBundleEntry.allCases {
                let path = bundle + (entry.relativePath.isEmpty ? "" : "/" + entry.relativePath)
                if entry.isDirectory {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                    guard Darwin.chmod(path, 0o755) == 0 else { throw POSIXError(.EIO) }
                } else {
                    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
                    guard Darwin.chmod(path, 0o644) == 0 else { throw POSIXError(.EIO) }
                }
            }
        }

        deinit {
            try? FileManager.default.removeItem(atPath: root)
        }

        func path(of entry: HelperBundleEntry) -> String {
            bundle + (entry.relativePath.isEmpty ? "" : "/" + entry.relativePath)
        }

        /// The device the layout is on.
        var device: dev_t {
            var status = stat()
            return lstat(bundle, &status) == 0 ? status.st_dev : 0
        }

        func inode(of entry: HelperBundleEntry) throws -> ino_t {
            var status = stat()
            guard lstat(path(of: entry), &status) == 0 else { throw POSIXError(.EIO) }
            return status.st_ino
        }

        func chmod(_ entry: HelperBundleEntry, _ mode: mode_t) throws {
            guard Darwin.chmod(path(of: entry), mode) == 0 else { throw POSIXError(.EIO) }
        }

        /// Lets the test's own user read the entry through an extended ACL entry, set with `acl_set_fd`.
        func addACL(to entry: HelperBundleEntry) throws {
            var userUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            guard mbr_uid_to_uuid(getuid(), &userUUID) == 0 else { throw POSIXError(.EIO) }
            var list: acl_t? = acl_init(1)
            defer { if let list { acl_free(UnsafeMutableRawPointer(list)) } }
            var aclEntry: acl_entry_t?
            var permissions: acl_permset_t?
            guard acl_create_entry(&list, &aclEntry) == 0,
                  acl_set_tag_type(aclEntry, ACL_EXTENDED_ALLOW) == 0,
                  withUnsafePointer(to: &userUUID, { acl_set_qualifier(aclEntry, $0) }) == 0,
                  acl_get_permset(aclEntry, &permissions) == 0,
                  acl_add_perm(permissions, ACL_READ_DATA) == 0,
                  acl_set_permset(aclEntry, permissions) == 0 else {
                throw POSIXError(.EIO)
            }
            let descriptor = open(path(of: entry), O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { close(descriptor) }
            guard acl_set_fd(descriptor, list) == 0 else { throw POSIXError(.EIO) }
        }
    }
}
