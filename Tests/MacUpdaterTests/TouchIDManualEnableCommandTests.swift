import Foundation
import Testing
@testable import WegaHelperKit

/// Aneks E.9 (Z1, Z2): the Terminal command that turns Touch ID for sudo on when the helper cannot.
/// The builder's script runs on the real `/bin/sh` and `/usr/bin` tools over temporary files, without
/// `sudo` and without `chown`, in Terminal's UTF-8 locale and in C. Its output keeps every line that
/// was there, so it must never launder a file someone other than root could change into root's.
@Suite("Touch ID — the manual enable command")
struct TouchIDManualEnableCommandTests {
    static let directive = Array((TouchIDSudoConfigurator.pamDirective + "\n").utf8)
    static let template = TouchIDDisableCommandTests.template

    struct WriteCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let sudoLocal: [UInt8]?
        let template: [UInt8]?
        let expected: [UInt8]
    }

    static let writeCases: [WriteCase] = [
        WriteCase(testDescription: "no sudo_local, Apple's template", sudoLocal: nil, template: template, expected: template + directive),
        WriteCase(testDescription: "no sudo_local and no template", sudoLocal: nil, template: nil, expected: directive),
        WriteCase(testDescription: "a comment", sudoLocal: Array("# a\n".utf8), template: template, expected: Array("# a\n".utf8) + directive),
        WriteCase(testDescription: "a last line without its newline", sudoLocal: Array("# c".utf8), template: nil,
                  expected: Array("# c\n".utf8) + directive),
        WriteCase(testDescription: "the directive already there", sudoLocal: directive, template: template, expected: directive),
        WriteCase(testDescription: "the directive already there, without its newline", sudoLocal: Array("# c\n".utf8) + directive.dropLast(),
                  template: nil, expected: Array("# c\n".utf8) + directive.dropLast()),
    ]

    static func script(in sandbox: PolicyShellSandbox, requiredOwnerUID: UInt32 = getuid(), ownership: String? = nil) -> String {
        TouchIDSudoConfigurator.manualEnableShellScript(
            target: sandbox.sudoLocal, stagingDirectory: sandbox.policyDirectory, template: sandbox.template,
            requiredOwnerUID: requiredOwnerUID, ownership: ownership)
    }

    /// M2: a step after the three temporary files were made fails (`chown` to root, as a user). The
    /// file stays as it was, or is still missing, and the trap removes the backup, the staged copy and
    /// the check copy, so no `.sudo_local.wega-*` name is left in the policy directory.
    @Test(arguments: [true, false], ShellLocale.allCases)
    func aFailureAfterStagingLeavesTheFileAndNoTemporaryFiles(_ hadSudoLocal: Bool, _ locale: ShellLocale) async throws {
        try #require(getuid() != 0, "the test needs chown to fail")
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        let original = Array("# a\n".utf8)
        if hadSudoLocal { try sandbox.write(original, to: sandbox.sudoLocal) }
        try sandbox.write(Self.template, to: sandbox.template, permissions: 0o444)

        let run = try await PolicyShell.run(Self.script(in: sandbox, ownership: "root:wheel"), in: locale)

        #expect(run.status != 0, "\(run.output)")
        if hadSudoLocal {
            #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(original))
        } else {
            #expect(!sandbox.exists(sandbox.sudoLocal))
        }
        let leftovers = try sandbox.leftovers()
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test(arguments: writeCases, ShellLocale.allCases)
    func theCommandAddsTheDirectiveOnceAndKeepsWhatWasThere(_ write: WriteCase, _ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        if let sudoLocal = write.sudoLocal { try sandbox.write(sudoLocal, to: sandbox.sudoLocal) }
        if let template = write.template { try sandbox.write(template, to: sandbox.template, permissions: 0o444) }

        let run = try await PolicyShell.run(Self.script(in: sandbox), in: locale)

        #expect(run.status == 0, "\(run.output)")
        #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(write.expected))
        #expect(try sandbox.permissions(of: sandbox.sudoLocal) == 0o644)
        #expect(try sandbox.leftovers().isEmpty)
        if let template = write.template {
            #expect(try sandbox.contents(of: sandbox.template) == Data(template), "the template is only read")
        }
    }

    struct UnsafeCase: Sendable, CustomTestStringConvertible {
        enum Kind: Sendable { case link, groupWritable, otherWritable, foreignOwner, accessControl, directory }
        let kind: Kind
        var testDescription: String { "\(kind)" }
    }

    /// Z1, M1: a `sudo_local` that is a link, not root's, writable by group or other or carrying an ACL
    /// is refused before anything is created, so its lines never end up in a root-owned file.
    @Test(arguments: [UnsafeCase.Kind.link, .groupWritable, .otherWritable, .foreignOwner, .accessControl, .directory]
            .map(UnsafeCase.init),
          ShellLocale.allCases)
    func anUnsafeSudoLocalIsRefusedAndNothingChanges(_ unsafe: UnsafeCase, _ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        try sandbox.write(Self.template, to: sandbox.template, permissions: 0o444)
        let original = Array("# a\n".utf8)
        var requiredOwnerUID = getuid()
        var checked = sandbox.sudoLocal
        switch unsafe.kind {
        case .link:
            checked = sandbox.moved("/elsewhere")
            try sandbox.write(original, to: checked)
            try FileManager.default.createSymbolicLink(atPath: sandbox.sudoLocal, withDestinationPath: checked)
        case .groupWritable:
            try sandbox.write(original, to: sandbox.sudoLocal, permissions: 0o664)
        case .otherWritable:
            try sandbox.write(original, to: sandbox.sudoLocal, permissions: 0o646)
        case .foreignOwner:
            try sandbox.write(original, to: sandbox.sudoLocal)
            requiredOwnerUID = getuid() &+ 1
        case .accessControl:
            try sandbox.write(original, to: sandbox.sudoLocal)
            try await sandbox.addAccessControlEntry(to: sandbox.sudoLocal)
        case .directory:
            try FileManager.default.createDirectory(atPath: sandbox.sudoLocal, withIntermediateDirectories: false)
        }

        let run = try await PolicyShell.run(Self.script(in: sandbox, requiredOwnerUID: requiredOwnerUID), in: locale)

        #expect(run.status == 1, "\(run.output)")
        #expect(try sandbox.leftovers().isEmpty, "nothing was created")
        switch unsafe.kind {
        case .link:
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.sudoLocal) == checked)
            #expect(try sandbox.contents(of: checked) == Data(original))
        case .directory:
            #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.sudoLocal).isEmpty)
        case .groupWritable, .otherWritable, .foreignOwner, .accessControl:
            #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(original))
        }
    }

    struct UnsafeTemplateCase: Sendable, CustomTestStringConvertible {
        enum Kind: Sendable { case link, danglingLink, groupWritable, otherWritable, foreignOwner, accessControl, directory }
        let kind: Kind
        var testDescription: String { "\(kind)" }
    }

    /// I1: with no `sudo_local`, the template is the base of a new root-owned file, so a template that
    /// is a link, not a regular file, not root's, writable by group or other or carrying an ACL is
    /// refused before anything is created. Its planted line never becomes active.
    @Test(arguments: [UnsafeTemplateCase.Kind.link, .danglingLink, .groupWritable, .otherWritable, .foreignOwner, .accessControl,
                      .directory].map(UnsafeTemplateCase.init),
          ShellLocale.allCases)
    func anUnsafeTemplateIsRefusedAndNothingIsCreated(_ unsafe: UnsafeTemplateCase, _ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        let planted = Array("auth       sufficient     pam_permit.so\n".utf8)
        var requiredOwnerUID = getuid()
        switch unsafe.kind {
        case .link:
            let elsewhere = sandbox.moved("/elsewhere")
            try sandbox.write(planted, to: elsewhere, permissions: 0o444)
            try FileManager.default.createSymbolicLink(atPath: sandbox.template, withDestinationPath: elsewhere)
        case .danglingLink:
            try FileManager.default.createSymbolicLink(atPath: sandbox.template, withDestinationPath: sandbox.moved("/nowhere"))
        case .groupWritable:
            try sandbox.write(planted, to: sandbox.template, permissions: 0o664)
        case .otherWritable:
            try sandbox.write(planted, to: sandbox.template, permissions: 0o666)
        case .foreignOwner:
            try sandbox.write(planted, to: sandbox.template, permissions: 0o444)
            requiredOwnerUID = getuid() &+ 1
        case .accessControl:
            try sandbox.write(planted, to: sandbox.template, permissions: 0o444)
            try await sandbox.addAccessControlEntry(to: sandbox.template)
        case .directory:
            try FileManager.default.createDirectory(atPath: sandbox.template, withIntermediateDirectories: false)
        }

        let run = try await PolicyShell.run(Self.script(in: sandbox, requiredOwnerUID: requiredOwnerUID), in: locale)

        #expect(run.status == 1, "\(run.output)")
        #expect(!sandbox.exists(sandbox.sudoLocal), "no sudo_local was created")
        #expect(try sandbox.leftovers().isEmpty, "nothing was created")
    }

    /// I1: the template is looked at only when it is the base. An existing `sudo_local` is the only
    /// base, so the command does not refuse it over a template it never reads.
    @Test(arguments: ShellLocale.allCases)
    func anUnsafeTemplateDoesNotMatterBesideAnExistingSudoLocal(_ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        try sandbox.write(Array("# a\n".utf8), to: sandbox.sudoLocal)
        try sandbox.write(Array("auth       sufficient     pam_permit.so\n".utf8), to: sandbox.template, permissions: 0o666)

        let run = try await PolicyShell.run(Self.script(in: sandbox), in: locale)

        #expect(run.status == 0, "\(run.output)")
        #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(Array("# a\n".utf8) + Self.directive))
        #expect(try sandbox.leftovers().isEmpty)
    }

    @Test func theProductionCommandRunsSudoFromUsrBinInTheCLocale() async throws {
        let command = TouchIDSudoConfigurator.manualEnableTerminalCommand
        let prefix = "/usr/bin/sudo /bin/sh -c '"
        #expect(command.hasPrefix(prefix + "set -eu; export LC_ALL=C; target=/etc/pam.d/sudo_local;"))
        #expect(command.hasSuffix("'") && !command.contains("\n"))
        for piece in [
            "/usr/bin/stat -f %u \"$target\"", "/usr/bin/stat -f %Lp \"$target\"", "[ \"$owner\" -ne 0 ]",
            "if [ -n \"$(/usr/bin/tail -c 1 \"$staged\")\" ]; then /bin/echo >> \"$staged\"; fi;",
            "/usr/sbin/chown root:wheel \"$staged\";", "/etc/pam.d/sudo_local.template",
            "/usr/bin/mktemp /etc/pam.d/.sudo_local.wega-backup.XXXXXX", "/usr/bin/mktemp /etc/pam.d/.sudo_local.wega-new.XXXXXX",
            "/usr/bin/mktemp /etc/pam.d/.sudo_local.wega-check.XXXXXX",
            "template=/etc/pam.d/sudo_local.template;", "/usr/bin/stat -f %u \"$template\"", "/usr/bin/stat -f %Lp \"$template\"",
            "[ \"$towner\" -ne 0 ]", "/bin/ls -lde \"$template\" | /usr/bin/grep -q \"^ [0-9][0-9]*: \"",
            "/bin/ls -lde \"$target\" | /usr/bin/grep -q \"^ [0-9][0-9]*: \"",
            "cleanup() { /bin/rm -f \"$staged\" \"$check\"; if [ \"$keep\" -eq 0 ]; then /bin/rm -f \"$backup\";",
            "if ! /bin/mv -f \"$staged\" \"$target\"; then rollback; exit 1; fi; keep=$had;",
        ] {
            #expect(command.contains(piece), "\(piece)")
        }
        let script = String(command.dropFirst(prefix.count).dropLast())
        let refusals = try #require(script.range(of: "nothing changed.\" >&2; exit 1; fi; fi;"))
        let firstTemporary = try #require(script.range(of: "/usr/bin/mktemp"))
        #expect(refusals.upperBound < firstTemporary.lowerBound, "the refusals come before anything is created")
        let everyRefusal = script.ranges(of: "nothing changed.")
        #expect(everyRefusal.count == 4, "sudo_local and the template, two refusals each")
        #expect(everyRefusal.allSatisfy { $0.upperBound < firstTemporary.lowerBound }, "every refusal comes before anything is created")
        let trap = try #require(script.range(of: "trap cleanup EXIT;"))
        #expect(trap.upperBound < firstTemporary.lowerBound, "M2: the trap is set before anything is created")
        #expect(!script.contains("'"))
        #expect(try await PolicyShell.run(script, in: .c, arguments: ["-n"]).status == 0, "valid shell")
    }
}
