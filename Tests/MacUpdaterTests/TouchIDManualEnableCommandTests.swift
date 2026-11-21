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

    static func script(in sandbox: PolicyShellSandbox, requiredOwnerUID: UInt32 = getuid()) -> String {
        TouchIDSudoConfigurator.manualEnableShellScript(
            target: sandbox.sudoLocal, stagingDirectory: sandbox.policyDirectory, template: sandbox.template,
            requiredOwnerUID: requiredOwnerUID, ownership: nil)
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
        enum Kind: Sendable { case link, groupWritable, otherWritable, foreignOwner, directory }
        let kind: Kind
        var testDescription: String { "\(kind)" }
    }

    /// Z1: a `sudo_local` that is a link, not root's, or writable by group or other is refused before
    /// anything is created, so its lines never end up in a root-owned file.
    @Test(arguments: [UnsafeCase.Kind.link, .groupWritable, .otherWritable, .foreignOwner, .directory].map(UnsafeCase.init),
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
        case .groupWritable, .otherWritable, .foreignOwner:
            #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(original))
        }
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
        ] {
            #expect(command.contains(piece), "\(piece)")
        }
        let script = String(command.dropFirst(prefix.count).dropLast())
        let refusals = try #require(script.range(of: "nothing changed.\" >&2; exit 1; fi; fi;"))
        let firstTemporary = try #require(script.range(of: "/usr/bin/mktemp"))
        #expect(refusals.upperBound < firstTemporary.lowerBound, "the refusals come before anything is created")
        #expect(!script.contains("'"))
        #expect(try await PolicyShell.run(script, in: .c, arguments: ["-n"]).status == 0, "valid shell")
    }
}
