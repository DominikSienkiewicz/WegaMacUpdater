import Darwin.membership
import Foundation
import Testing
@testable import WegaHelperKit

/// The live policy directory over a real temporary directory: the same system calls the root
/// helper makes on `/private/etc/pam.d`, run unprivileged on files the test owns. Nothing here
/// touches `/etc`; the owner the gates require is the test's own uid.
///
/// Every path is built under a `realpath`-resolved temporary directory: `/var` is itself a link to
/// `/private/var`, and the directory is opened with no link allowed in any component.
@Suite("Turning off Touch ID for sudo on a real directory")
struct TouchIDSudoDisableFileSystemTests {
    let wega = TouchIDSudoConfigurator.pamDirective
    let template = "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "# uncomment following line to enable Touch ID for sudo\n"
        + "#auth       sufficient     pam_tid.so\n"
    let admin = TouchIDSudoDisabler.Caller(uid: 501, consoleUserUID: 501, isAdministrator: true)

    // MARK: - Primitives

    @Test func theVolumeSwapsTwoNamesAtomically() throws {
        try withScratch { base in
            try write("one", to: base + "/a")
            try write("two", to: base + "/b")
            let directory = try SystemPAMPolicyDirectory(path: base)
            #expect(try directory.supportsSwap(), "APFS supports RENAME_SWAP")
            let a = try #require(try directory.facts(named: "a"))
            let b = try #require(try directory.facts(named: "b"))

            try directory.swap("a", "b")

            #expect(try directory.facts(named: "a")?.identity == b.identity)
            #expect(try directory.facts(named: "b")?.identity == a.identity)
            #expect(try String(contentsOfFile: base + "/a", encoding: .utf8) == "two")
            #expect(throws: POSIXError.self) { try directory.swap("a", "missing") }
            try directory.synchronize()
        }
    }

    @Test func theDirectoryIsOpenedWithNoLinkAnywhere() throws {
        try withScratch { base in
            try makeDirectory(base + "/real")
            try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")
            #expect(throws: POSIXError.self) { try SystemPAMPolicyDirectory(path: base + "/link") }
            #expect(throws: POSIXError.self) { try SystemPAMPolicyDirectory(path: base + "/link/.") }

            let facts = try SystemPAMPolicyDirectory(path: base + "/real").directoryFacts()
            #expect(facts == PAMPolicyDirectoryFacts(isDirectory: true, ownerUID: getuid(), permissions: 0o755, accessControl: .absent))
        }
    }

    @Test func aLinkADirectoryAndAFIFOAreNotRegularFiles() throws {
        try withScratch { base in
            try write(wega + "\n", to: base + "/target")
            let entries: [(String, (String) throws -> Void)] = [
                ("link", { try FileManager.default.createSymbolicLink(atPath: $0, withDestinationPath: base + "/target") }),
                ("directory", { try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: false) }),
                ("fifo", { path in
                    guard mkfifo(path, 0o644) == 0 else { throw POSIXError(.EIO) }
                }),
            ]
            for (name, make) in entries {
                let policy = base + "/" + name
                try makeDirectory(policy)
                try make(policy + "/sudo_local")
                let directory = try SystemPAMPolicyDirectory(path: policy)
                #expect(try directory.readPolicyFile(named: "sudo_local", limit: 100) == .notRegular, "\(name)")
                #expect(run(in: policy).result == .refused(.notRegularFile), "\(name)")
            }
            #expect(try String(contentsOfFile: base + "/target", encoding: .utf8) == wega + "\n")
        }
    }

    @Test func aReadTakesAtMostOneByteOverTheLimit() throws {
        try withScratch { base in
            try write("#" + String(repeating: "x", count: 69_999), to: base + "/sudo_local")
            let directory = try SystemPAMPolicyDirectory(path: base)
            guard case .read(let facts, let data) = try directory.readPolicyFile(named: "sudo_local", limit: 100) else {
                Issue.record("a regular file must be read")
                return
            }
            #expect(data.count == 101)
            #expect(facts.size == 70_000)
            #expect(try directory.readPolicyFile(named: "missing", limit: 100) == .missing)
            #expect(run(in: base).result == .refused(.tooLarge))
        }
    }

    @Test func creatingNeverReplacesAnExistingName() throws {
        try withScratch { base in
            try write("keep", to: base + "/taken")
            let directory = try SystemPAMPolicyDirectory(path: base)
            #expect(throws: POSIXError(.EEXIST)) {
                try directory.createFile(named: "taken", contents: Data("new".utf8), owner: getuid(), group: getgid(), permissions: 0o644)
            }
            #expect(try String(contentsOfFile: base + "/taken", encoding: .utf8) == "keep")
        }
    }

    @Test func aCreatedFileHasExactlyTheBytesOwnerGroupAndMode() throws {
        try withScratch { base in
            let directory = try SystemPAMPolicyDirectory(path: base)
            let facts = try directory.createFile(
                named: "new", contents: Data("# c\n".utf8), owner: getuid(), group: getgid(), permissions: 0o440
            )
            #expect(facts.isRegularFile && facts.ownerUID == getuid() && facts.groupID == getgid())
            #expect(facts.permissions == 0o440)
            #expect(facts.accessControl == .absent)
            #expect(facts.size == 4)
            #expect(try String(contentsOfFile: base + "/new", encoding: .utf8) == "# c\n")
            #expect(try directory.facts(named: "new")?.identity == facts.identity)
        }
    }

    /// Changing the owner to root fails unprivileged, which is how a failure after creation is
    /// produced here: the name must not stay behind.
    @Test func aCreationThatFailsHalfwayLeavesNoFile() throws {
        try withScratch { base in
            let directory = try SystemPAMPolicyDirectory(path: base)
            #expect(throws: POSIXError(.EPERM)) {
                try directory.createFile(named: "new", contents: Data("x".utf8), owner: 0, group: getgid(), permissions: 0o644)
            }
            #expect(!FileManager.default.fileExists(atPath: base + "/new"))
        }
    }

    @Test func aNameIsRemovedOnlyWhileItNamesTheGivenFile() throws {
        try withScratch { base in
            try write("a", to: base + "/a")
            try write("b", to: base + "/b")
            let directory = try SystemPAMPolicyDirectory(path: base)
            let b = try #require(try directory.facts(named: "b"))
            #expect(try directory.remove(named: "a", ifIdentity: b.identity) == false)
            #expect(FileManager.default.fileExists(atPath: base + "/a"))
            #expect(try directory.remove(named: "b", ifIdentity: b.identity))
            #expect(!FileManager.default.fileExists(atPath: base + "/b"))
            #expect(try directory.remove(named: "b", ifIdentity: b.identity) == false)
        }
    }

    @Test func aNameWithASlashIsRefused() throws {
        try withScratch { base in
            try FileManager.default.createDirectory(atPath: base + "/sub", withIntermediateDirectories: false)
            try write("x", to: base + "/sub/sudo_local")
            let directory = try SystemPAMPolicyDirectory(path: base)
            #expect(throws: POSIXError(.EINVAL)) { try directory.facts(named: "sub/sudo_local") }
            #expect(throws: POSIXError(.EINVAL)) { try directory.readPolicyFile(named: "..", limit: 10) }
        }
    }

    @Test func anACLIsSeenOnTheFileAndRefused() throws {
        try withScratch { base in
            try write(template + wega + "\n", to: base + "/sudo_local")
            try addReadACL(to: base + "/sudo_local")
            let directory = try SystemPAMPolicyDirectory(path: base)
            #expect(try directory.facts(named: "sudo_local")?.accessControl == .present)
            #expect(run(in: base).result == .refused(.unsafeOwnership))
            #expect(try String(contentsOfFile: base + "/sudo_local", encoding: .utf8) == template + wega + "\n")
        }
    }

    @Test func aLaterPolicyPathIsFoundWithoutFollowingIt() throws {
        try withScratch { base in
            try write("x", to: base + "/file")
            try FileManager.default.createSymbolicLink(atPath: base + "/dangling", withDestinationPath: base + "/nowhere")
            #expect(TouchIDSudoDisabler.fallbackPolicyEntryExists(atPath: base + "/file"))
            #expect(TouchIDSudoDisabler.fallbackPolicyEntryExists(atPath: base + "/dangling"), "a link counts, wherever it points")
            #expect(!TouchIDSudoDisabler.fallbackPolicyEntryExists(atPath: base + "/missing"))
            #expect(!TouchIDSudoDisabler.fallbackPolicyEntryExists(atPath: base + "/file/below"), "ENOTDIR")
        }
    }

    // MARK: - The whole operation

    /// A hard link keeps the old bytes under its own name: the swap moves `sudo_local` to a new
    /// file and leaves the original inode where its other names are. The original's `ctime`
    /// changes with the swap, and the operation still passes, because no snapshot includes it.
    @Test func theOperationKeepsTheModesAndAHardLinkKeepsTheOldBytes() throws {
        for mode: UInt16 in [0o640, 0o444] {
            try withScratch { base in
                let path = base + "/sudo_local"
                try write(template + wega + "\n", to: path, mode: mode)
                guard link(path, base + "/other") == 0 else { throw POSIXError(.EIO) }
                let before = try status(base + "/other")

                let report = run(in: base)

                #expect(report == TouchIDSudoDisableReport(result: .removed(lines: 1), linkCount: 2), "\(mode)")
                #expect(try String(contentsOfFile: path, encoding: .utf8) == template)
                let after = try status(path)
                #expect(after.st_mode & 0o7777 == mode_t(mode))
                #expect(after.st_uid == before.st_uid && after.st_gid == before.st_gid)
                #expect(after.st_ino != before.st_ino, "a new file")
                #expect(try String(contentsOfFile: base + "/other", encoding: .utf8) == template + wega + "\n")
                let other = try status(base + "/other")
                #expect(other.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec
                        || other.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec, "the swap changed ctime")
                let names = try FileManager.default.contentsOfDirectory(atPath: base)
                #expect(Set(names) == ["sudo_local", "other"], "no swap name is left")
            }
        }
    }

    @Test func theOperationOnARealDirectoryLeavesAnEmptyFileNeverNone() throws {
        try withScratch { base in
            try write(wega + "\n", to: base + "/sudo_local")
            #expect(run(in: base).result == .removed(lines: 1))
            #expect(try Data(contentsOf: URL(fileURLWithPath: base + "/sudo_local")).isEmpty)
            #expect(run(in: base).result == .nothingToRemove)
            #expect(run(in: base + "/missing-directory").result == .refused(.unreadable))
        }
    }

    // MARK: - Helpers

    private func run(in path: String) -> TouchIDSudoDisableReport {
        TouchIDSudoDisabler.run(
            caller: admin,
            openDirectory: { try SystemPAMPolicyDirectory(path: path) },
            fallbackExists: { _ in false },
            makeName: TouchIDSudoDisabler.makeSwapName,
            requiredOwnerUID: getuid()
        )
    }

    private func withScratch(_ body: (String) throws -> Void) throws {
        let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let base = String(cString: temporary) + "/wega-pam-\(UUID().uuidString)"
        try makeDirectory(base)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try body(base)
    }

    /// `0755` whatever the umask, so the directory passes the policy directory's gate.
    private func makeDirectory(_ path: String) throws {
        guard mkdir(path, 0o755) == 0, chmod(path, 0o755) == 0 else { throw POSIXError(.EIO) }
    }

    private func write(_ text: String, to path: String, mode: UInt16 = 0o644) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        guard chmod(path, mode_t(mode)) == 0 else { throw POSIXError(.EIO) }
    }

    private func status(_ path: String) throws -> stat {
        var result = stat()
        guard lstat(path, &result) == 0 else { throw POSIXError(.ENOENT) }
        return result
    }

    /// Lets the test's own user read the file through an extended ACL entry, set with `acl_set_fd`.
    private func addReadACL(to path: String) throws {
        var userUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        guard mbr_uid_to_uuid(getuid(), &userUUID) == 0 else { throw POSIXError(.EIO) }
        var list: acl_t? = acl_init(1)
        defer { if let list { acl_free(UnsafeMutableRawPointer(list)) } }
        var entry: acl_entry_t?
        var permissions: acl_permset_t?
        guard acl_create_entry(&list, &entry) == 0,
              acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0,
              withUnsafePointer(to: &userUUID, { acl_set_qualifier(entry, $0) }) == 0,
              acl_get_permset(entry, &permissions) == 0,
              acl_add_perm(permissions, ACL_READ_DATA) == 0,
              acl_set_permset(entry, permissions) == 0 else {
            throw POSIXError(.EIO)
        }
        let file = open(path, O_RDONLY)
        guard file >= 0 else { throw POSIXError(.EIO) }
        defer { close(file) }
        guard acl_set_fd(file, list) == 0 else { throw POSIXError(.EIO) }
    }
}
