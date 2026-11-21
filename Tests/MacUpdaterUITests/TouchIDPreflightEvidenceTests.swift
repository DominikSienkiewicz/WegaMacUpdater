import Darwin
import Foundation
@testable import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// RC2-6: the card offers a `sudo` command, or the helper's button, only on positive evidence that
/// what `sudo` reads first is root's alone: `/etc/pam.d`, `sudo_local` and `/etc/pam.d/sudo`. Anything
/// the app could not establish counts like −5. `refusal` keeps its meaning: what the helper's own
/// gates would say about the facts the app saw.
@Suite("Touch ID — sudo only on proof that its settings are safe")
struct TouchIDPreflightEvidenceTests {
    typealias Preflight = TouchIDDisablePreflight

    private func directory(owner: UInt32 = 0, permissions: UInt16 = 0o755, acl: PAMAccessControlState = .absent,
                           isDirectory: Bool = true) -> PAMPolicyDirectoryFacts {
        PAMPolicyDirectoryFacts(isDirectory: isDirectory, ownerUID: owner, permissions: permissions, accessControl: acl)
    }

    private func file(owner: UInt32 = 0, permissions: UInt16 = 0o444, acl: PAMAccessControlState = .absent,
                      isRegular: Bool = true, size: Int64 = 40) -> PAMPolicyFileFacts {
        PAMPolicyFileFacts(
            isRegularFile: isRegular, identity: PAMFileIdentity(device: 1, inode: 2), linkCount: 1, ownerUID: owner,
            groupID: 0, permissions: permissions, accessControl: acl, size: size, modifiedNanoseconds: 0)
    }

    private func observed(
        directory: Preflight.Lookup<PAMPolicyDirectoryFacts>? = nil, sudoLocal: Preflight.Lookup<PAMPolicyFileFacts>? = nil,
        sudo: Preflight.Lookup<PAMPolicyFileFacts>? = nil, template: Preflight.Lookup<PAMPolicyFileFacts>? = nil
    ) -> Preflight {
        Preflight.evaluate(.init(
            policyDirectory: directory ?? .found(self.directory()), sudoLocal: sudoLocal ?? .found(file(permissions: 0o644)),
            sudoPolicy: sudo ?? .found(file()), template: template ?? .found(file()), localDirectories: [], existingFallbackPaths: []))
    }

    @Test func rootsAloneEverywhereIsProof() {
        let safe = observed()
        #expect(safe.commandsAreSafe && !safe.sudoPolicyIsUnsafe && safe.refusal == nil)
        #expect(observed(sudoLocal: .missing).commandsAreSafe, "no sudo_local at all (ENOENT) is safe")
        #expect(observed(sudoLocal: .found(file(size: 70_000))).commandsAreSafe, "its size is no safety question")
        #expect(Preflight.clear.commandsAreSafe, "the all-clear preflight carries the proof")
    }

    @Test func anythingTheAppCouldNotEstablishIsNoProof() {
        let cases: [(String, Preflight)] = [
            ("/etc/pam.d not looked at", observed(directory: .unknown)),
            ("/etc/pam.d missing", observed(directory: .missing)),
            ("/etc/pam.d ACL unreadable", observed(directory: .found(directory(acl: .unreadable)))),
            ("sudo_local not looked at", observed(sudoLocal: .unknown)),
            ("sudo_local ACL unreadable", observed(sudoLocal: .found(file(acl: .unreadable)))),
            ("/etc/pam.d/sudo missing", observed(sudo: .missing)),
            ("/etc/pam.d/sudo not looked at", observed(sudo: .unknown)),
            ("/etc/pam.d/sudo ACL unreadable", observed(sudo: .found(file(acl: .unreadable)))),
        ]
        for (name, preflight) in cases {
            #expect(!preflight.commandsAreSafe, "\(name)")
            #expect(preflight.refusal == nil && !preflight.sudoPolicyIsUnsafe, "\(name): nothing was seen to be wrong")
        }
    }

    @Test func whatTheHelperWouldRefuseIsNoProofEither() {
        let cases: [(name: String, refused: (Preflight, TouchIDSudoDisableRefusal))] = [
            ("sudo_local a link", (observed(sudoLocal: .found(file(isRegular: false))), .notRegularFile)),
            ("sudo_local 0664", (observed(sudoLocal: .found(file(permissions: 0o664))), .unsafeOwnership)),
            ("sudo_local with an ACL", (observed(sudoLocal: .found(file(acl: .present))), .unsafeOwnership)),
            ("/etc/pam.d 0775", (observed(directory: .found(directory(permissions: 0o775))), .unsafeOwnership)),
        ]
        for (name, (preflight, refusal)) in cases {
            #expect(preflight.refusal == refusal && !preflight.commandsAreSafe, "\(name)")
        }
    }

    /// I1: with no `sudo_local`, the enable command and the helper copy the template into a new
    /// root-owned file, so the proof needs the template missing, or root's alone with its ACL read as
    /// absent. Beside an existing `sudo_local` the template is never the base and does not count.
    @Test func withNoSudoLocalTheTemplateMustBeRootsAloneToo() {
        #expect(observed(sudoLocal: .missing, template: .missing).commandsAreSafe, "no template: an empty base")
        #expect(observed(sudoLocal: .missing, template: .found(file())).commandsAreSafe, "Apple's root:wheel 0444 template")
        #expect(observed(sudoLocal: .missing, template: .found(file(size: 70_000))).commandsAreSafe, "its size is no safety question")
        let cases: [(String, Preflight.Lookup<PAMPolicyFileFacts>)] = [
            ("a link", .found(file(isRegular: false))), ("owner 501", .found(file(owner: 501))),
            ("0664", .found(file(permissions: 0o664))), ("0666", .found(file(permissions: 0o666))),
            ("an ACL", .found(file(acl: .present))), ("an ACL the app could not read", .found(file(acl: .unreadable))),
            ("not looked at", .unknown),
        ]
        for (name, template) in cases {
            let preflight = observed(sudoLocal: .missing, template: template)
            #expect(!preflight.commandsAreSafe, "\(name)")
            #expect(preflight.refusal == nil && !preflight.sudoPolicyIsUnsafe, "\(name): neither the disable gates nor sudo read it")
            #expect(observed(template: template).commandsAreSafe, "\(name): beside a sudo_local it is never the base")
        }
        let unlooked = Preflight.evaluate(.init(
            policyDirectory: .found(directory()), sudoLocal: .missing, sudoPolicy: .found(file()), localDirectories: [],
            existingFallbackPaths: []))
        #expect(!unlooked.commandsAreSafe, "an observation that names no template proves nothing")
    }

    /// `/etc/pam.d/sudo` is a plain data-volume file: someone other than root who can write it can
    /// give `sudo` a module that takes the password.
    @Test func anUnsafeSudoFileIsSeenAsSuch() {
        let cases: [(String, PAMPolicyFileFacts)] = [
            ("not a regular file", file(isRegular: false)), ("owner 501", file(owner: 501)),
            ("0664", file(permissions: 0o664)), ("0446", file(permissions: 0o446)), ("an ACL", file(acl: .present)),
        ]
        for (name, facts) in cases {
            let preflight = observed(sudo: .found(facts))
            #expect(preflight.sudoPolicyIsUnsafe && !preflight.commandsAreSafe, "\(name)")
            #expect(preflight.refusal == nil, "\(name): the helper's gates never read this file")
        }
    }

    /// The lookup tells "nothing has the name" from "the app could not look".
    @Test func theLookupTellsAMissingNameFromAFailure() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wega-preflight-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let regular = base + "/sudo_local"
        try Data("# a\n".utf8).write(to: URL(fileURLWithPath: regular))
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: regular)

        let found = try #require(Preflight.policyFile(at: regular).facts)
        #expect(found.isRegularFile && found.ownerUID == getuid() && found.size == 4 && found.accessControl == .absent)
        #expect(Preflight.policyFile(at: base + "/link").facts?.isRegularFile == false, "a link is not followed")
        #expect(Preflight.policyFile(at: base + "/none") == .missing)
        #expect(Preflight.policyFile(at: regular + "/child") == .unknown, "ENOTDIR is not ENOENT")
        #expect(Preflight.policyDirectory(at: base).facts?.isDirectory == true)
        #expect(Preflight.policyDirectory(at: base + "/none") == .missing)
    }
}
