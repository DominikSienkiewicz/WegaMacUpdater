import Foundation
import Testing
@testable import WegaHelperKit

/// The disable transaction over an in-memory policy directory: the order of its steps, what each
/// failure leaves behind, and that the original is swapped back only over the helper's own file.
@Suite("Turning off Touch ID for sudo: the transaction")
struct TouchIDSudoDisableTransactionTests {
    typealias Entry = PAMPolicyDirectoryFake.Entry
    typealias Caller = TouchIDSudoDisabler.Caller

    let wega = TouchIDSudoConfigurator.pamDirective
    let template = "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "# uncomment following line to enable Touch ID for sudo\n"
        + "#auth       sufficient     pam_tid.so\n"
    let swapName = ".sudo_local.wega-swap-T"
    let admin = Caller(uid: 501, consoleUserUID: 501, isAdministrator: true)
    var swapPath: String { "/etc/pam.d/" + swapName }
    var fallbacks: [String] { TouchIDSudoDisabler.fallbackPolicyPaths.map { "fallback \($0)" } }

    private func enabled(permissions: UInt16 = 0o644) -> PAMPolicyDirectoryFake {
        .holding(template + wega + "\n", permissions: permissions)
    }

    private func run(_ fake: PAMPolicyDirectoryFake, caller: Caller? = nil) -> TouchIDSudoDisableReport {
        TouchIDSudoDisabler.run(
            caller: caller ?? admin, openDirectory: { fake }, fallbackExists: fake.fallbackExists, makeName: { swapName }
        )
    }

    // MARK: - Success

    @Test func aRemovalSwapsInAVerifiedFileWithTheOriginalsOwnerGroupAndMode() throws {
        let fake = enabled(permissions: 0o444)
        fake.entries["sudo_local"]?.groupID = 7
        let original = try #require(fake.entries["sudo_local"])

        #expect(run(fake) == TouchIDSudoDisableReport(result: .removed(lines: 1)))
        #expect(fake.events == ["directory", "read sudo_local"] + fallbacks + [
            "capability", "create \(swapName)", "swap \(swapName) sudo_local", "sync",
            "facts \(swapName)", "facts sudo_local", "read sudo_local", "remove \(swapName)",
        ])
        let placed = try #require(fake.entries["sudo_local"])
        #expect(placed.data == Data(template.utf8))
        #expect(placed.identity != original.identity)
        #expect(placed.permissions == 0o444)
        #expect(placed.ownerUID == 0)
        #expect(placed.groupID == 7)
        #expect(fake.entries[swapName] == nil, "the original, swapped out, is removed")
    }

    @Test func aSecondRunHasNothingLeftToRemove() {
        let fake = enabled()
        #expect(run(fake).result == .removed(lines: 1))
        #expect(run(fake) == TouchIDSudoDisableReport(result: .nothingToRemove))
    }

    @Test func aSecondNameIsLoggedNotRefused() {
        let fake = enabled()
        fake.entries["sudo_local"]?.linkCount = 2
        #expect(run(fake) == TouchIDSudoDisableReport(result: .removed(lines: 1), linkCount: 2))
    }

    // MARK: - Nothing touched

    @Test func aCallerWhoMayNotAskOpensNothing() {
        let callers: [(Caller, TouchIDSudoDisableRefusal)] = [
            (Caller(uid: 501, consoleUserUID: nil, isAdministrator: true), .noConsoleUser),
            (Caller(uid: 502, consoleUserUID: 501, isAdministrator: true), .callerNotConsoleUser),
            (Caller(uid: 501, consoleUserUID: 501, isAdministrator: false), .callerNotAdministrator),
        ]
        for (caller, refusal) in callers {
            let fake = enabled()
            var opened = 0
            let report = TouchIDSudoDisabler.run(
                caller: caller, openDirectory: { opened += 1; return fake },
                fallbackExists: fake.fallbackExists, makeName: { swapName }
            )
            #expect(report == TouchIDSudoDisableReport(result: .refused(refusal), failedStep: .caller))
            #expect(opened == 0, "the directory is never opened")
            #expect(fake.events.isEmpty)
        }
    }

    /// The live entry point applies the same gate before it opens anything, so this touches no file.
    @Test func theLiveOperationRefusesACallerBeforeOpeningTheRealDirectory() {
        let report = TouchIDSudoDisabler.runLive(caller: Caller(uid: 501, consoleUserUID: nil, isAdministrator: true))
        #expect(report == TouchIDSudoDisableReport(result: .refused(.noConsoleUser), failedStep: .caller))
    }

    @Test func anUnsafeOrUnopenableDirectoryIsRefusedBeforeTheFileIsRead() {
        let unsafe = enabled()
        unsafe.directory.permissions = 0o775
        #expect(run(unsafe) == TouchIDSudoDisableReport(result: .refused(.unsafeOwnership), failedStep: .directory))
        #expect(unsafe.events == ["directory"])

        let unreadable = enabled()
        unreadable.fail("directory", with: .EIO)
        #expect(run(unreadable) == TouchIDSudoDisableReport(result: .refused(.unreadable), failedStep: .directory))

        for (code, refusal) in [(POSIXErrorCode.ELOOP, TouchIDSudoDisableRefusal.unsafeOwnership), (.ENOENT, .unreadable)] {
            let report = TouchIDSudoDisabler.run(
                caller: admin, openDirectory: { throw POSIXError(code) }, fallbackExists: { _ in false }, makeName: { swapName }
            )
            #expect(report == TouchIDSudoDisableReport(result: .refused(refusal), failedStep: .directory), "\(code)")
        }
    }

    @Test func noFileOrNoDirectiveWritesNothing() {
        let missing = PAMPolicyDirectoryFake()
        #expect(run(missing) == TouchIDSudoDisableReport(result: .nothingToRemove))
        #expect(missing.events == ["directory", "read sudo_local"], "a missing file is never created")

        let factory = PAMPolicyDirectoryFake.holding(template)
        #expect(run(factory) == TouchIDSudoDisableReport(result: .nothingToRemove))
        #expect(factory.events == ["directory", "read sudo_local"])
    }

    private struct RefusalCase {
        let name: String
        let change: (PAMPolicyDirectoryFake) -> Void
        let refusal: TouchIDSudoDisableRefusal
        let step: TouchIDSudoDisableStep
    }

    @Test func everyRefusalOfTheFileOrItsContentsCreatesNothing() throws {
        let cases = [
            RefusalCase(name: "link", change: { $0.entries["sudo_local"]?.kind = .symlink }, refusal: .notRegularFile, step: .read),
            RefusalCase(name: "fifo", change: { $0.entries["sudo_local"]?.kind = .fifo }, refusal: .notRegularFile, step: .read),
            RefusalCase(name: "directory", change: { $0.entries["sudo_local"]?.kind = .directory }, refusal: .notRegularFile, step: .read),
            RefusalCase(name: "owner", change: { $0.entries["sudo_local"]?.ownerUID = 501 }, refusal: .unsafeOwnership, step: .read),
            RefusalCase(name: "mode", change: { $0.entries["sudo_local"]?.permissions = 0o666 }, refusal: .unsafeOwnership, step: .read),
            RefusalCase(name: "acl", change: { $0.entries["sudo_local"]?.accessControl = .present }, refusal: .unsafeOwnership, step: .read),
            RefusalCase(name: "unreadable acl", change: { $0.entries["sudo_local"]?.accessControl = .unreadable },
                        refusal: .unsafeOwnership, step: .read),
            RefusalCase(name: "size", change: { $0.entries["sudo_local"]?.reportedSize = 65_537 }, refusal: .tooLarge, step: .read),
            RefusalCase(name: "grew past the limit", change: {
                $0.entries["sudo_local"]?.data = Data(repeating: 0x23, count: 70_000)
                $0.entries["sudo_local"]?.reportedSize = 100
            }, refusal: .tooLarge, step: .read),
            RefusalCase(name: "size differs from bytes", change: { $0.entries["sudo_local"]?.reportedSize = 10 },
                        refusal: .changedDuringOperation, step: .read),
            RefusalCase(name: "exchanged while opened", change: { $0.readAnswers[1] = .changed },
                        refusal: .changedDuringOperation, step: .read),
            RefusalCase(name: "not UTF-8", change: { $0.entries["sudo_local"]?.data = Data([0xFF, 0x0A]) + Data(wega.utf8) },
                        refusal: .unreadable, step: .plan),
            RefusalCase(name: "backslash", change: { $0.entries["sudo_local"]?.data = Data(("\\\n" + wega).utf8) },
                        refusal: .lineContinuation, step: .plan),
            RefusalCase(name: "deny line", change: {
                $0.entries["sudo_local"]?.data = Data((wega + "\nauth       required       pam_deny.so\n").utf8)
            }, refusal: .otherDirectivesPresent, step: .plan),
        ]
        for item in cases {
            let fake = enabled()
            item.change(fake)
            let before = fake.entries
            #expect(run(fake) == TouchIDSudoDisableReport(result: .refused(item.refusal), failedStep: item.step), "\(item.name)")
            #expect(!fake.events.contains { $0.hasPrefix("create") || $0.hasPrefix("swap") }, "\(item.name)")
            #expect(fake.entries == before, "\(item.name)")
        }

        let failing = enabled()
        failing.fail("read sudo_local", with: .EIO)
        #expect(run(failing) == TouchIDSudoDisableReport(result: .refused(.unreadable), failedStep: .read))
    }

    @Test func aLaterPolicyFileRefusesTheRemoval() {
        let fake = enabled()
        fake.existingFallbacks = ["/usr/local/etc/pam.d/sudo_local"]
        #expect(run(fake) == TouchIDSudoDisableReport(
            result: .refused(.fallbackPolicyPresent), failedStep: .fallback,
            fallbackPolicyPath: "/usr/local/etc/pam.d/sudo_local"
        ))
        #expect(fake.events == ["directory", "read sudo_local", "fallback /etc/pam.conf", "fallback /usr/local/etc/pam.d/sudo_local"])
    }

    @Test func withoutSwapSupportNothingIsCreated() {
        let unsupported = enabled()
        unsupported.swapSupported = false
        let failing = enabled()
        failing.fail("capability", with: .EIO)
        for fake in [unsupported, failing] {
            #expect(run(fake) == TouchIDSudoDisableReport(result: .restoredAfterFailure, failedStep: .capability))
            #expect(!fake.events.contains("create \(swapName)"))
        }
    }

    // MARK: - Failures before the swap

    @Test func aFailedCreationChangesNothing() throws {
        let fake = enabled()
        let original = try #require(fake.entries["sudo_local"])
        fake.fail("create \(swapName)", with: .EIO)
        #expect(run(fake) == TouchIDSudoDisableReport(result: .restoredAfterFailure, failedStep: .temporary))
        #expect(fake.entries == ["sudo_local": original])
        #expect(!fake.events.contains { $0.hasPrefix("swap") })
    }

    @Test func aFailedSwapRemovesTheNewFile() throws {
        let cases: [(POSIXErrorCode, TouchIDSudoDisableResult)] = [
            (.ENOTSUP, .restoredAfterFailure), (.EPERM, .restoredAfterFailure), (.ENOENT, .refused(.changedDuringOperation)),
        ]
        for (code, result) in cases {
            let fake = enabled()
            let original = try #require(fake.entries["sudo_local"])
            fake.fail("swap \(swapName) sudo_local", with: code)
            #expect(run(fake) == TouchIDSudoDisableReport(result: result, failedStep: .swap), "\(code)")
            #expect(fake.entries == ["sudo_local": original], "\(code)")
            #expect(fake.events.last == "remove \(swapName)", "\(code)")
        }
    }

    // MARK: - Failures after the swap: swapping back

    @Test func aFailedDirectoryFlushSwapsTheOriginalBack() throws {
        let fake = enabled()
        let original = try #require(fake.entries["sudo_local"])
        fake.fail("sync", with: .EIO)
        #expect(run(fake) == TouchIDSudoDisableReport(result: .restoredAfterFailure, failedStep: .directorySync))
        #expect(fake.entries == ["sudo_local": original])
        #expect(Array(fake.events.suffix(6)) == [
            "sync", "facts sudo_local", "swap \(swapName) sudo_local", "sync", "facts sudo_local", "remove \(swapName)",
        ])
    }

    /// S9: the file swapped out must be the file that was read. If another root writer changed or
    /// replaced it in between, its file goes back and nothing is changed.
    @Test func aFileChangedBeforeTheSwapIsPutBack() throws {
        let changes: [(String, (PAMPolicyDirectoryFake) -> Void)] = [
            ("replaced", { $0.replace("sudo_local", with: "# someone else\n") }),
            ("grown in place", { $0.entries["sudo_local"]?.data.append(contentsOf: Data("# more\n".utf8)) }),
            ("touched in place", { $0.entries["sudo_local"]?.modified += 1 }),
        ]
        for (name, change) in changes {
            let fake = enabled()
            var changed: Entry?
            fake.after("read sudo_local") {
                change($0)
                changed = $0.entries["sudo_local"]
            }
            #expect(run(fake) == TouchIDSudoDisableReport(result: .refused(.changedDuringOperation), failedStep: .swappedOutCheck),
                    "\(name)")
            #expect(fake.entries == ["sudo_local": try #require(changed)], "\(name): the other writer's file is back")
        }
    }

    @Test func aFailedVerificationSwapsTheOriginalBack() throws {
        let damages: [(String, (PAMPolicyDirectoryFake) -> Void)] = [
            ("foreign bytes", { $0.entries["sudo_local"]?.data = Data("# not the plan\n".utf8) }),
            ("lost mode", { $0.entries["sudo_local"]?.permissions = 0o600 }),
            ("lost owner", { $0.entries["sudo_local"]?.ownerUID = 501 }),
            ("lost group", { $0.entries["sudo_local"]?.groupID = 20 }),
            ("an ACL", { $0.entries["sudo_local"]?.accessControl = .present }),
            ("an active line", { $0.entries["sudo_local"]?.data = Data("auth       required       pam_deny.so\n".utf8) }),
            ("another inode on reading back", {
                $0.readAnswers[2] = .read(
                    $0.facts(of: Entry(identity: PAMFileIdentity(device: 1, inode: 999), data: Data(template.utf8))),
                    Data(template.utf8)
                )
            }),
            ("exchanged on reading back", { $0.readAnswers[2] = .changed }),
        ]
        for (name, damage) in damages {
            let fake = enabled()
            let original = try #require(fake.entries["sudo_local"])
            fake.after("swap \(swapName) sudo_local", damage)
            #expect(run(fake) == TouchIDSudoDisableReport(result: .restoredAfterFailure, failedStep: .verify), "\(name)")
            #expect(fake.entries == ["sudo_local": original], "\(name)")
        }
    }

    /// Security re-check: a file another root writer put in place after the swap is never swapped
    /// out again; the original stays under the swap name.
    @Test func aFileReplacedAfterTheSwapIsLeftAlone() throws {
        let fake = enabled()
        let original = try #require(fake.entries["sudo_local"])
        var foreign: Entry?
        fake.after("swap \(swapName) sudo_local") {
            $0.replace("sudo_local", with: "# root wrote this\n")
            foreign = $0.entries["sudo_local"]
        }
        #expect(run(fake) == TouchIDSudoDisableReport(
            result: .refused(.changedDuringOperation), failedStep: .swapBack, leftBehindPath: swapPath
        ))
        #expect(fake.entries["sudo_local"] == foreign)
        #expect(fake.entries[swapName] == original)
        #expect(fake.events.filter { $0.hasPrefix("swap") }.count == 1, "no swap back over another writer's file")
    }

    /// Security re-check: −21 only when the swap back itself fails, so the swap name holds the original.
    @Test func aFailedSwapBackSaysWhereTheOriginalIs() throws {
        let fake = enabled()
        let original = try #require(fake.entries["sudo_local"])
        fake.after("swap \(swapName) sudo_local") { $0.entries["sudo_local"]?.data = Data("# damaged\n".utf8) }
        fake.fail("swap \(swapName) sudo_local", occurrence: 2, with: .EIO)
        #expect(run(fake) == TouchIDSudoDisableReport(result: .rollbackFailed(backupPath: swapPath), failedStep: .swapBack))
        #expect(fake.entries[swapName] == original, "the swap name holds the original")
        #expect(!fake.events.contains("remove \(swapName)"))
    }

    /// Security re-check: a swap back that finds a file other than the original reports a change,
    /// not a failed rollback.
    @Test func aSwapBackThatFindsAnotherFileIsAChange() {
        let fake = enabled()
        fake.after("swap \(swapName) sudo_local") { $0.entries["sudo_local"]?.data = Data("# damaged\n".utf8) }
        fake.after("swap \(swapName) sudo_local", occurrence: 2) { $0.replace("sudo_local", with: "# raced\n") }
        #expect(run(fake) == TouchIDSudoDisableReport(result: .refused(.changedDuringOperation), failedStep: .swapBackVerify))
        #expect(fake.entries[swapName] == nil, "the new file is still removed by its identity")
        #expect(fake.entries["sudo_local"]?.data == Data("# raced\n".utf8))
    }

    // MARK: - Cleanup

    @Test func theSwapNameIsRemovedOnlyWhileItStillNamesTheOriginal() {
        let fake = enabled()
        var foreign: Entry?
        fake.after("read sudo_local", occurrence: 2) {
            $0.replace(swapName, with: "# not ours\n")
            foreign = $0.entries[swapName]
        }
        #expect(run(fake) == TouchIDSudoDisableReport(result: .removed(lines: 1), failedStep: .cleanup, leftBehindPath: swapPath))
        #expect(fake.entries[swapName] == foreign, "a name that points elsewhere is never removed")
        #expect(fake.entries["sudo_local"]?.data == Data(template.utf8))
    }

    @Test func aFailedCleanupIsStillASuccess() throws {
        let fake = enabled()
        let original = try #require(fake.entries["sudo_local"])
        fake.fail("remove \(swapName)", with: .EIO)
        #expect(run(fake) == TouchIDSudoDisableReport(result: .removed(lines: 1), failedStep: .cleanup, leftBehindPath: swapPath))
        #expect(fake.entries[swapName] == original)
    }
}
