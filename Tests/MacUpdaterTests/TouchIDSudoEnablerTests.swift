import Darwin.membership
import Foundation
import Testing
@testable import WegaHelperKit

/// Turning Touch ID for `sudo` on as root (Aneks E.1, E.2, E.9): the caller first, then the policy
/// directory, `sudo_local` or the template through the same descriptor, the plan on the bytes read,
/// one write and a readback through the descriptor. Over an in-memory directory, and over a real
/// temporary one with the test's own uid as the owner the gates require; nothing touches `/etc`.
@Suite("Turning on Touch ID for sudo: the operation")
struct TouchIDSudoEnablerTests {
    typealias Entry = PAMPolicyDirectoryFake.Entry
    typealias Caller = TouchIDSudoDisabler.Caller

    let wega = TouchIDSudoConfigurator.pamDirective
    let template = "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "# uncomment following line to enable Touch ID for sudo\n"
        + "#auth       sufficient     pam_tid.so\n"
    let admin = Caller(uid: 501, consoleUserUID: 501, isAdministrator: true)

    /// Plays the live writer: the planned bytes under `sudo_local`, a new file, root's, `0644`.
    private final class Writer {
        var writes: [Data] = []
        var error: Error?
        var place: ((PAMPolicyDirectoryFake, Data) -> Void)?

        func write(_ data: Data, into fake: PAMPolicyDirectoryFake) throws {
            writes.append(data)
            if let error { throw error }
            if let place { return place(fake, data) }
            fake.entries["sudo_local"] = Entry(identity: fake.newIdentity(), data: data)
        }
    }

    private func run(_ fake: PAMPolicyDirectoryFake, writer: Writer = Writer(), caller: Caller? = nil) -> TouchIDSudoEnableReport {
        TouchIDSudoEnabler.run(caller: caller ?? admin, openDirectory: { fake }, write: { try writer.write($0, into: fake) })
    }

    private func withTemplate(_ text: String, sudoLocal: String? = nil) -> PAMPolicyDirectoryFake {
        let fake = PAMPolicyDirectoryFake(entries: [
            "sudo_local.template": Entry(identity: PAMFileIdentity(device: 1, inode: 2), data: Data(text.utf8)),
        ])
        if let sudoLocal { fake.entries["sudo_local"] = Entry(identity: PAMFileIdentity(device: 1, inode: 1), data: Data(sudoLocal.utf8)) }
        return fake
    }

    // MARK: - Who may ask (E.1)

    @Test func aStandardUserIsRefusedBeforeAnyFileIsTouched() {
        let callers: [(Caller, TouchIDSudoEnableRefusal)] = [
            (Caller(uid: 501, consoleUserUID: nil, isAdministrator: true), .noConsoleUser),
            (Caller(uid: 502, consoleUserUID: 501, isAdministrator: true), .callerNotConsoleUser),
            (Caller(uid: 501, consoleUserUID: 501, isAdministrator: false), .callerNotAdministrator),
        ]
        for (caller, refusal) in callers {
            let fake = withTemplate(template)
            let writer = Writer()
            var opened = 0
            let report = TouchIDSudoEnabler.run(
                caller: caller, openDirectory: { opened += 1; return fake }, write: { try writer.write($0, into: fake) }
            )
            #expect(report == TouchIDSudoEnableReport(result: .refused(refusal), failedStep: .caller), "\(refusal)")
            #expect(opened == 0, "the directory is never opened")
            #expect(fake.events.isEmpty && writer.writes.isEmpty)
        }
        var opened = 0
        let fake = withTemplate(template)
        _ = TouchIDSudoEnabler.run(caller: admin, openDirectory: { opened += 1; return fake }, write: { _ in })
        #expect(opened == 1, "the administrator at the console gets past the caller gate")
    }

    /// The live entry point applies the same gate before it opens anything, so this touches no file.
    @Test func theLiveOperationRefusesACallerBeforeOpeningTheRealDirectory() {
        let report = TouchIDSudoEnabler.runLive(caller: Caller(uid: 501, consoleUserUID: nil, isAdministrator: true))
        #expect(report == TouchIDSudoEnableReport(result: .refused(.noConsoleUser), failedStep: .caller))
    }

    // MARK: - The directory (E.2 step 2)

    @Test func anUnsafeOrUnopenableDirectoryIsRefusedBeforeAnyFileIsRead() {
        let unsafe: [(String, (PAMPolicyDirectoryFake) -> Void)] = [
            ("0775", { $0.directory.permissions = 0o775 }), ("0757", { $0.directory.permissions = 0o757 }),
            ("owner", { $0.directory.ownerUID = 501 }), ("acl", { $0.directory.accessControl = .present }),
            ("unreadable acl", { $0.directory.accessControl = .unreadable }),
        ]
        for (name, change) in unsafe {
            let fake = withTemplate(template)
            change(fake)
            let writer = Writer()
            #expect(run(fake, writer: writer) == TouchIDSudoEnableReport(result: .refused(.unsafeOwnership), failedStep: .directory), "\(name)")
            #expect(fake.events == ["directory"] && writer.writes.isEmpty, "\(name)")
        }
        let unreadable = withTemplate(template)
        unreadable.fail("directory", with: .EIO)
        #expect(run(unreadable) == TouchIDSudoEnableReport(result: .refused(.unreadable), failedStep: .directory))
        for (code, refusal) in [(POSIXErrorCode.ELOOP, TouchIDSudoEnableRefusal.unsafeOwnership), (.ENOENT, .unreadable)] {
            let report = TouchIDSudoEnabler.run(caller: admin, openDirectory: { throw POSIXError(code) }, write: { _ in })
            #expect(report == TouchIDSudoEnableReport(result: .refused(refusal), failedStep: .directory), "\(code)")
        }
    }

    // MARK: - sudo_local (E.2 step 3)

    private struct RefusalCase {
        let name: String
        let change: (PAMPolicyDirectoryFake) -> Void
        let refusal: TouchIDSudoEnableRefusal
        let step: TouchIDSudoEnableStep
    }

    @Test func everyRefusalOfSudoLocalWritesNothing() {
        let cases = [
            RefusalCase(name: "link", change: { $0.entries["sudo_local"]?.kind = .symlink }, refusal: .notRegularFile, step: .read),
            RefusalCase(name: "fifo", change: { $0.entries["sudo_local"]?.kind = .fifo }, refusal: .notRegularFile, step: .read),
            RefusalCase(name: "owner", change: { $0.entries["sudo_local"]?.ownerUID = 501 }, refusal: .unsafeOwnership, step: .read),
            RefusalCase(name: "0664", change: { $0.entries["sudo_local"]?.permissions = 0o664 }, refusal: .unsafeOwnership, step: .read),
            RefusalCase(name: "acl", change: { $0.entries["sudo_local"]?.accessControl = .present }, refusal: .unsafeOwnership, step: .read),
            RefusalCase(name: "unreadable acl", change: { $0.entries["sudo_local"]?.accessControl = .unreadable },
                        refusal: .unsafeOwnership, step: .read),
            RefusalCase(name: "65 537 B", change: { $0.entries["sudo_local"]?.reportedSize = 65_537 }, refusal: .tooLarge, step: .read),
            RefusalCase(name: "grew past the limit", change: {
                $0.entries["sudo_local"]?.data = Data(repeating: 0x23, count: 70_000)
                $0.entries["sudo_local"]?.reportedSize = 100
            }, refusal: .tooLarge, step: .read),
            RefusalCase(name: "size differs from bytes", change: { $0.entries["sudo_local"]?.reportedSize = 3 },
                        refusal: .changedDuringOperation, step: .read),
            RefusalCase(name: "exchanged between fstatat and open", change: { $0.readAnswers[1] = .changed },
                        refusal: .changedDuringOperation, step: .read),
            RefusalCase(name: "not UTF-8", change: { $0.entries["sudo_local"]?.data = Data([0xFF, 0x0A]) },
                        refusal: .unreadable, step: .plan),
            RefusalCase(name: "NUL", change: { $0.entries["sudo_local"]?.data = Data("# a\n".utf8) + Data([0x00, 0x0A]) },
                        refusal: .unreadable, step: .plan),
        ]
        for item in cases {
            let fake = withTemplate(template, sudoLocal: "# local\n")
            item.change(fake)
            let before = fake.entries
            let writer = Writer()
            #expect(run(fake, writer: writer) == TouchIDSudoEnableReport(result: .refused(item.refusal), failedStep: item.step), "\(item.name)")
            #expect(writer.writes.isEmpty, "\(item.name)")
            #expect(fake.entries == before, "\(item.name)")
            #expect(!fake.events.contains("read sudo_local.template"), "\(item.name): an existing sudo_local is the only base")
        }
        let failing = withTemplate(template, sudoLocal: "# local\n")
        failing.fail("read sudo_local", with: .EIO)
        #expect(run(failing) == TouchIDSudoEnableReport(result: .refused(.unreadable), failedStep: .read))
    }

    /// RC2-2: 0 means `sudo_local` itself holds an active line; nothing is read or written after it.
    @Test func anActiveLineInSudoLocalWritesNothing() {
        let fake = withTemplate(template, sudoLocal: template + wega + "\n")
        let writer = Writer()
        #expect(run(fake, writer: writer) == TouchIDSudoEnableReport(result: .alreadyEnabled))
        #expect(writer.writes.isEmpty)
        #expect(fake.events == ["directory", "read sudo_local"])
    }

    @Test func aSuccessWritesExactlyThePlannedBytesOnceAndReadsThemBack() {
        let fake = withTemplate(template, sudoLocal: "# local")
        let writer = Writer()
        #expect(run(fake, writer: writer) == TouchIDSudoEnableReport(result: .enabled))
        #expect(writer.writes == [Data(("# local\n" + wega + "\n").utf8)])
        #expect(fake.events == ["directory", "read sudo_local", "read sudo_local"], "the readback goes through the same descriptor")
    }

    // MARK: - The template (E.2 step 4)

    @Test func theTemplateIsTheBaseOnlyWhenSudoLocalIsMissing() {
        let fake = withTemplate(template)
        let writer = Writer()
        #expect(run(fake, writer: writer) == TouchIDSudoEnableReport(result: .enabled))
        #expect(writer.writes == [Data((template + wega + "\n").utf8)])
        #expect(fake.events == ["directory", "read sudo_local", "read sudo_local.template", "read sudo_local"])

        let bare = PAMPolicyDirectoryFake()
        let bareWriter = Writer()
        #expect(run(bare, writer: bareWriter) == TouchIDSudoEnableReport(result: .enabled))
        #expect(bareWriter.writes == [Data((wega + "\n").utf8)], "no template: an empty base")
    }

    /// RC2-2: a template that already holds the line is still written, because `sudo` reads only
    /// `sudo_local`; it is written as it is, with no second directive.
    @Test func aTemplateThatAlreadyEnablesItIsStillWritten() {
        let active = template + wega + "\n"
        let fake = withTemplate(active)
        let writer = Writer()
        #expect(run(fake, writer: writer) == TouchIDSudoEnableReport(result: .enabled))
        #expect(writer.writes == [Data(active.utf8)])
    }

    @Test func anUnsafeTemplateIsRefusedLikeSudoLocal() {
        let cases = [
            RefusalCase(name: "link", change: { $0.entries["sudo_local.template"]?.kind = .symlink }, refusal: .notRegularFile, step: .template),
            RefusalCase(name: "owner", change: { $0.entries["sudo_local.template"]?.ownerUID = 501 }, refusal: .unsafeOwnership, step: .template),
            RefusalCase(name: "0666", change: { $0.entries["sudo_local.template"]?.permissions = 0o666 }, refusal: .unsafeOwnership, step: .template),
            RefusalCase(name: "acl", change: { $0.entries["sudo_local.template"]?.accessControl = .present }, refusal: .unsafeOwnership, step: .template),
            RefusalCase(name: "65 537 B", change: { $0.entries["sudo_local.template"]?.reportedSize = 65_537 }, refusal: .tooLarge, step: .template),
            RefusalCase(name: "exchanged", change: { $0.readAnswers[2] = .changed }, refusal: .changedDuringOperation, step: .template),
            RefusalCase(name: "not UTF-8", change: { $0.entries["sudo_local.template"]?.data = Data([0xFE]) }, refusal: .unreadable, step: .plan),
        ]
        for item in cases {
            let fake = withTemplate(template)
            item.change(fake)
            let writer = Writer()
            #expect(run(fake, writer: writer) == TouchIDSudoEnableReport(result: .refused(item.refusal), failedStep: item.step), "\(item.name)")
            #expect(writer.writes.isEmpty, "\(item.name)")
        }
        let failing = withTemplate(template)
        failing.fail("read sudo_local.template", with: .EIO)
        #expect(run(failing) == TouchIDSudoEnableReport(result: .refused(.unreadable), failedStep: .template))
    }

    // MARK: - The write (E.2 step 6, E.3)

    @Test func aWriterThatCouldNotUndoTheWriteNamesItsBackup() {
        typealias WriteError = SudoLocalTransactionalWriter.WriteError
        let cases: [(String?, String?)] = [
            ("/private/etc/pam.d/.sudo_local.wega-backup-0A1B", "/etc/pam.d/.sudo_local.wega-backup-0A1B"), (nil, nil),
        ]
        for (thrown, reported) in cases {
            let writer = Writer()
            writer.error = WriteError.rollbackFailed(backupPath: thrown)
            #expect(run(withTemplate(template, sudoLocal: "# a\n"), writer: writer)
                    == TouchIDSudoEnableReport(result: .rollbackFailed(backupPath: reported), failedStep: .write))
        }
    }

    @Test func anyOtherWriterErrorMeansThePreviousStateIsBack() {
        for error in [SudoLocalTransactionalWriter.WriteError.verificationFailed, POSIXError(.EIO)] as [Error] {
            let writer = Writer()
            writer.error = error
            #expect(run(withTemplate(template, sudoLocal: "# a\n"), writer: writer)
                    == TouchIDSudoEnableReport(result: .restoredAfterFailure, failedStep: .write), "\(error)")
            #expect(writer.writes.count == 1)
        }
    }

    // MARK: - The readback (Z7)

    @Test func theFileReadBackMustBeThePlannedOneRootsAloneWithNoACL() {
        let wrong: [(String, (PAMPolicyDirectoryFake, Data) -> Void)] = [
            ("nothing written", { _, _ in }),
            ("other bytes", { fake, _ in fake.replace("sudo_local", with: "# other\n") }),
            ("owner", { fake, data in fake.entries["sudo_local"] = Entry(identity: fake.newIdentity(), data: data, ownerUID: 501) }),
            ("0664", { fake, data in fake.entries["sudo_local"] = Entry(identity: fake.newIdentity(), data: data, permissions: 0o664) }),
            ("acl", { fake, data in fake.entries["sudo_local"] = Entry(identity: fake.newIdentity(), data: data, accessControl: .present) }),
            ("link", { fake, data in fake.entries["sudo_local"] = Entry(kind: .symlink, identity: fake.newIdentity(), data: data) }),
        ]
        // I1: the write happened and the writer has removed its backup, so "nothing changed" would be
        // false; the state is unknown, and that is what −21 without a path says.
        let unknown = TouchIDSudoEnableReport(result: .rollbackFailed(backupPath: nil), failedStep: .verify)
        for (name, place) in wrong {
            let writer = Writer()
            writer.place = place
            #expect(run(withTemplate(template, sudoLocal: "# a\n"), writer: writer) == unknown, "\(name)")
        }
        let failing = withTemplate(template, sudoLocal: "# a\n")
        failing.fail("read sudo_local", occurrence: 2, with: .EIO)
        #expect(run(failing) == unknown, "a failed read is no proof either")
    }

    /// The writer reported success, yet no file is there: its state is not known, and there is no backup.
    @Test func noFileAfterAWriteIsARollbackWithoutABackup() {
        let writer = Writer()
        writer.place = { fake, _ in fake.entries["sudo_local"] = nil }
        #expect(run(withTemplate(template), writer: writer)
                == TouchIDSudoEnableReport(result: .rollbackFailed(backupPath: nil), failedStep: .verify))
    }

    // MARK: - A real directory

    @Test func aSymlinkedSudoLocalIsRefusedWithoutFollowingIt() throws {
        try withScratch { base in
            try write(template, to: base + "/target")
            try FileManager.default.createSymbolicLink(atPath: base + "/sudo_local", withDestinationPath: base + "/target")
            var writes = 0
            #expect(runReal(in: base, write: { _ in writes += 1 }) == TouchIDSudoEnableReport(result: .refused(.notRegularFile), failedStep: .read))
            #expect(writes == 0)
            #expect(try String(contentsOfFile: base + "/target", encoding: .utf8) == template)
        }
    }

    @Test func aSymlinkedTemplateIsRefusedWithoutFollowingIt() throws {
        try withScratch { base in
            try write(template, to: base + "/target")
            try FileManager.default.createSymbolicLink(atPath: base + "/sudo_local.template", withDestinationPath: base + "/target")
            #expect(runReal(in: base, write: { _ in }) == TouchIDSudoEnableReport(result: .refused(.notRegularFile), failedStep: .template))
        }
    }

    @Test func anACLOnSudoLocalIsRefused() throws {
        try withScratch { base in
            try write("# local\n", to: base + "/sudo_local")
            try addReadACL(to: base + "/sudo_local")
            var writes = 0
            #expect(runReal(in: base, write: { _ in writes += 1 }) == TouchIDSudoEnableReport(result: .refused(.unsafeOwnership), failedStep: .read))
            #expect(writes == 0)
        }
    }

    @Test func aDirectoryReachedThroughALinkIsRefused() throws {
        try withScratch { base in
            try makeDirectory(base + "/real")
            try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")
            #expect(runReal(in: base + "/link", write: { _ in }) == TouchIDSudoEnableReport(result: .refused(.unsafeOwnership), failedStep: .directory))
        }
    }

    @Test func theOperationOnARealDirectoryWritesTheTemplateWithTheDirectiveAndReadsItBack() throws {
        try withScratch { base in
            try write(template, to: base + "/sudo_local.template")
            let target = URL(fileURLWithPath: base + "/sudo_local")
            let atomic: (Data) throws -> Void = { try $0.write(to: target, options: .atomic) }
            #expect(runReal(in: base, write: atomic) == TouchIDSudoEnableReport(result: .enabled))
            #expect(try String(contentsOf: target, encoding: .utf8) == template + wega + "\n")
            #expect(runReal(in: base, write: atomic) == TouchIDSudoEnableReport(result: .alreadyEnabled))
        }
    }

    // MARK: - Helpers

    private func runReal(in path: String, write: (Data) throws -> Void) -> TouchIDSudoEnableReport {
        TouchIDSudoEnabler.run(
            caller: admin, openDirectory: { try SystemPAMPolicyDirectory(path: path) }, write: write, requiredOwnerUID: getuid()
        )
    }

    /// Under a `realpath`-resolved temporary directory: `/var` is itself a link to `/private/var`,
    /// and the directory is opened with no link allowed in any component.
    private func withScratch(_ body: (String) throws -> Void) throws {
        let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let base = String(cString: temporary) + "/wega-pam-enable-\(UUID().uuidString)"
        try makeDirectory(base)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try body(base)
    }

    /// `0755` whatever the umask, so the directory passes the policy directory's gate.
    private func makeDirectory(_ path: String) throws {
        guard mkdir(path, 0o755) == 0, chmod(path, 0o755) == 0 else { throw POSIXError(.EIO) }
    }

    private func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        guard chmod(path, 0o644) == 0 else { throw POSIXError(.EIO) }
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
