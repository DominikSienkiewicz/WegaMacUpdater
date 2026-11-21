import Foundation
import Testing
@testable import WegaHelperKit

/// Aneks E.6, E.9 (RC2-5, Z2, Z3): the Terminal command that turns Touch ID for sudo off without the
/// helper. The builder's script runs on the real `/bin/sh` and `/usr/bin` tools over temporary files,
/// without `sudo` and without `chown`, in Terminal's UTF-8 locale and in C, and it must decide every
/// file the way the helper's own plan does.
@Suite("Touch ID — the disable command without the helper")
struct TouchIDDisableCommandTests {
    static let directive = Array(TouchIDSudoConfigurator.pamDirective.utf8)
    static let template = Array((
        "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "# uncomment following line to enable Touch ID for sudo\n"
        + "#auth       sufficient     pam_tid.so\n"
    ).utf8)
    static let newline = Array("\n".utf8)

    struct ContentCase: Sendable, CustomTestStringConvertible {
        enum Outcome: Sendable {
            /// Exit 1 and the file byte for byte as it was.
            case refused
            /// Exit 0 and the file byte for byte as it was.
            case untouched
            /// Exit 0 and exactly these bytes, mode 0644.
            case becomes([UInt8])
        }

        let testDescription: String
        let file: [UInt8]
        let outcome: Outcome
    }

    static let contentCases: [ContentCase] = [
        ContentCase(testDescription: "the template and the directive", file: template + directive + newline, outcome: .becomes(template)),
        ContentCase(testDescription: "the directive alone", file: directive + newline, outcome: .becomes([])),
        ContentCase(testDescription: "the directive without its newline after a comment",
                    file: Array("# c\n".utf8) + directive, outcome: .becomes(Array("# c\n".utf8))),
        ContentCase(testDescription: "the directive at the size limit",
                    file: directive + newline + Array("#".utf8) + [UInt8](repeating: 0x78, count: TouchIDSudoDisabler.maximumSize - directive.count - 3) + newline,
                    outcome: .becomes(Array("#".utf8) + [UInt8](repeating: 0x78, count: TouchIDSudoDisabler.maximumSize - directive.count - 3) + newline)),
        ContentCase(testDescription: "the directive ending in CR", file: directive + Array("\r\n".utf8), outcome: .untouched),
        ContentCase(testDescription: "no directive", file: template, outcome: .untouched),
        ContentCase(testDescription: "a backslash in a comment", file: directive + newline + Array("# a \\\n".utf8), outcome: .refused),
        ContentCase(testDescription: "a NUL byte", file: directive + newline + Array("#".utf8) + [0] + newline, outcome: .refused),
        ContentCase(testDescription: "bytes that are not UTF-8", file: directive + newline + Array("# ".utf8) + [0xFF] + newline, outcome: .refused),
        ContentCase(testDescription: "one byte over the size limit",
                    file: directive + newline + Array("#".utf8) + [UInt8](repeating: 0x78, count: TouchIDSudoDisabler.maximumSize - directive.count - 2) + newline,
                    outcome: .refused),
        ContentCase(testDescription: "a comment behind U+00A0", file: directive + newline + Array("\u{00A0}# c\n".utf8), outcome: .refused),
        ContentCase(testDescription: "a comment behind U+3000", file: directive + newline + Array("\u{3000}# c\n".utf8), outcome: .refused),
        ContentCase(testDescription: "another active line", file: directive + newline + Array("auth       required       pam_deny.so\n".utf8),
                    outcome: .refused),
    ]

    static func script(in sandbox: PolicyShellSandbox, ownership: String? = nil) -> String {
        TouchIDSudoConfigurator.disableShellScript(
            target: sandbox.sudoLocal, stagingDirectory: sandbox.policyDirectory, fallbackPaths: sandbox.fallbackPaths,
            localDirectories: sandbox.localDirectories, ownership: ownership)
    }

    // MARK: - What the file holds

    @Test(arguments: contentCases, ShellLocale.allCases)
    func theCommandDecidesEveryFileTheWayTheHelperDoes(_ content: ContentCase, _ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        try sandbox.write(content.file, to: sandbox.sudoLocal)

        let run = try await PolicyShell.run(Self.script(in: sandbox), in: locale)
        let after = try sandbox.contents(of: sandbox.sudoLocal)
        let plan = TouchIDSudoConfigurator.contentsDisablingTouchID(current: Data(content.file))
        switch content.outcome {
        case .refused:
            #expect(run.status == 1, "\(run.output)")
            #expect(after == Data(content.file))
            guard case .refused = plan else { Issue.record("the helper plans \(plan)"); break }
        case .untouched:
            #expect(run.status == 0, "\(run.output)")
            #expect(after == Data(content.file))
            #expect(plan == .nothingToRemove)
        case .becomes(let expected):
            #expect(run.status == 0, "\(run.output)")
            #expect(after == Data(expected))
            #expect(try sandbox.permissions(of: sandbox.sudoLocal) == 0o644)
            guard case .remove(_, let contents) = plan else { Issue.record("the helper plans \(plan)"); break }
            #expect(contents == Data(expected), "the helper writes the same bytes")
        }
        #expect(try sandbox.leftovers().isEmpty)
    }

    /// Review focus 4: the user pastes the command after another line was added to the file.
    @Test(arguments: ShellLocale.allCases)
    func theCommandRefusesAFileThatGainedAnActiveLine(_ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        let file = Self.directive + Self.newline + Array("auth       required       pam_deny.so\n".utf8)
        try sandbox.write(file, to: sandbox.sudoLocal)

        let run = try await PolicyShell.run(Self.script(in: sandbox), in: locale)

        #expect(run.status == 1, "\(run.output)")
        #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(file))
        #expect(try sandbox.leftovers().isEmpty)
    }

    /// RC2-5: the shell's `[[:space:]]` follows the locale, so without `LC_ALL=C` a comment behind a
    /// no-break space would pass in Terminal's locale. This shows the test's two locales really differ.
    @Test func terminalsLocaleWouldTreatANoBreakSpaceAsBlank() async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        let path = sandbox.moved("/line")
        try sandbox.write(Array("\u{00A0}# c\n".utf8), to: path)
        let activeLines = #"/usr/bin/grep -c -v -E "^[[:space:]]*(#|$)" "# + path + " || true"

        #expect(try await PolicyShell.run(activeLines, in: .polishUTF8).output == "0\n")
        #expect(try await PolicyShell.run(activeLines, in: .c).output == "1\n")
    }

    // MARK: - What surrounds the file

    @Test(arguments: ShellLocale.allCases)
    func aLinkedSudoLocalIsRefusedAndNotFollowed(_ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        let elsewhere = sandbox.moved("/elsewhere")
        let file = Self.directive + Self.newline
        try sandbox.write(file, to: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: sandbox.sudoLocal, withDestinationPath: elsewhere)

        let run = try await PolicyShell.run(Self.script(in: sandbox), in: locale)

        #expect(run.status == 1, "\(run.output)")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.sudoLocal) == elsewhere)
        #expect(try sandbox.contents(of: elsewhere) == Data(file))
        #expect(try sandbox.leftovers().isEmpty)
    }

    /// −9: once nothing is active in `sudo_local`, `sudo` would read the next policy file.
    @Test(arguments: 0..<TouchIDSudoDisabler.fallbackPolicyPaths.count, ShellLocale.allCases)
    func aLaterPolicyFileStopsTheCommand(_ index: Int, _ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        let file = Self.directive + Self.newline
        try sandbox.write(file, to: sandbox.sudoLocal)
        try sandbox.write(Array("auth sufficient pam_permit.so\n".utf8), to: sandbox.fallbackPaths[index])

        let run = try await PolicyShell.run(Self.script(in: sandbox), in: locale)

        #expect(run.status == 1, "\(run.output)")
        #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(file))
        #expect(try sandbox.leftovers().isEmpty)
    }

    @Test(arguments: ShellLocale.allCases)
    func aDanglingLinkAtALaterPolicyPathStopsTheCommandToo(_ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        let file = Self.directive + Self.newline
        try sandbox.write(file, to: sandbox.sudoLocal)
        try FileManager.default.createSymbolicLink(atPath: sandbox.fallbackPaths[0], withDestinationPath: sandbox.moved("/nowhere"))

        let run = try await PolicyShell.run(Self.script(in: sandbox), in: locale)

        #expect(run.status == 1, "\(run.output)")
        #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(file))
    }

    /// Z3: a link anywhere in the `/usr/local` chain can point `sudo` at settings outside root's reach.
    @Test(arguments: 0..<3, ShellLocale.allCases)
    func aLinkInTheLocalChainStopsTheCommand(_ index: Int, _ locale: ShellLocale) async throws {
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        let file = Self.directive + Self.newline
        try sandbox.write(file, to: sandbox.sudoLocal)
        let link = sandbox.localDirectories[index]
        let target = sandbox.moved("/elsewhere-directory")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: link).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let run = try await PolicyShell.run(Self.script(in: sandbox), in: locale)

        #expect(run.status == 1, "\(run.output)")
        #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(file))
        #expect(try sandbox.leftovers().isEmpty)
    }

    /// A step after the new file was made fails (`chown` to root, as a user): the file stays as it
    /// was, and the trap removes the new file.
    @Test(arguments: ShellLocale.allCases)
    func aFailureAfterStagingLeavesTheFileAndNoStagedCopy(_ locale: ShellLocale) async throws {
        try #require(getuid() != 0, "the test needs chown to fail")
        let sandbox = try PolicyShellSandbox()
        defer { sandbox.remove() }
        let file = Self.template + Self.directive + Self.newline
        try sandbox.write(file, to: sandbox.sudoLocal)

        let run = try await PolicyShell.run(Self.script(in: sandbox, ownership: "root:wheel"), in: locale)

        #expect(run.status != 0, "\(run.output)")
        #expect(try sandbox.contents(of: sandbox.sudoLocal) == Data(file))
        #expect(try sandbox.leftovers().isEmpty)
    }

    // MARK: - The production command

    /// The text the security review approved (Aneks E.9), one line.
    static let reviewedCommand = #"""
    /usr/bin/sudo /bin/sh -c 'set -eu; export LC_ALL=C; target=/etc/pam.d/sudo_local; line="auth       sufficient     pam_tid.so"; staged="";
    trap "/bin/rm -f \"\$staged\"" EXIT;
    if [ ! -f "$target" ] || [ -L "$target" ]; then echo "Wega: sudo_local is not a regular file; nothing changed." >&2; exit 1; fi;
    if [ "$(/usr/bin/stat -f %z "$target")" -gt 65536 ]; then echo "Wega: sudo_local is too large; nothing changed." >&2; exit 1; fi;
    if ! /usr/bin/tr -d "\000" < "$target" | /usr/bin/cmp -s - "$target"; then echo "Wega: sudo_local contains a NUL byte; nothing changed." >&2; exit 1; fi;
    if ! /usr/bin/iconv -f UTF-8 -t UTF-8 "$target" > /dev/null 2>&1; then echo "Wega: sudo_local is not UTF-8; nothing changed." >&2; exit 1; fi;
    if ! /usr/bin/grep -q -x -F "$line" "$target"; then echo "Wega: no exact pam_tid line; nothing changed."; exit 0; fi;
    if /usr/bin/grep -q -F "\\" "$target"; then echo "Wega: sudo_local contains a backslash; nothing changed." >&2; exit 1; fi;
    if /usr/bin/grep -v -x -F "$line" "$target" | /usr/bin/grep -q -v -E "^[[:space:]]*(#|$)"; then echo "Wega: sudo_local has other settings; nothing changed." >&2; exit 1; fi;
    for d in /usr/local /usr/local/etc /usr/local/etc/pam.d; do if [ -L "$d" ]; then echo "Wega: $d is a link; nothing changed." >&2; exit 1; fi; done;
    for p in /etc/pam.conf /usr/local/etc/pam.d/sudo_local /usr/local/etc/pam.conf /usr/share/pam.d/sudo_local; do
    if [ -e "$p" ] || [ -L "$p" ]; then echo "Wega: $p exists; nothing changed." >&2; exit 1; fi; done;
    staged=$(/usr/bin/mktemp /etc/pam.d/.sudo_local.wega-new.XXXXXX);
    /usr/bin/grep -v -x -F "$line" "$target" > "$staged" || [ $? -eq 1 ];
    /usr/sbin/chown root:wheel "$staged"; /bin/chmod 0644 "$staged";
    /bin/mv -f "$staged" "$target"; echo "Wega: Touch ID for sudo is off. Check: sudo -k; sudo true"'
    """#.components(separatedBy: "\n").joined(separator: " ")

    @Test func theProductionCommandIsTheReviewedOne() async throws {
        let command = TouchIDSudoConfigurator.manualDisableTerminalCommand
        #expect(command == Self.reviewedCommand)
        #expect(!command.contains("\n"), "one line, so it pastes cleanly")
        let prefix = "/usr/bin/sudo /bin/sh -c '"
        #expect(command.hasPrefix(prefix) && command.hasSuffix("'"), "Z2: no sudo found on a PATH the user controls")
        let pieces = [
            "export LC_ALL=C", "/usr/sbin/chown root:wheel \"$staged\"", "/bin/mv -f \"$staged\" \"$target\"",
            "/usr/bin/mktemp /etc/pam.d/.sudo_local.wega-new.XXXXXX", "line=\"\(TouchIDSudoConfigurator.pamDirective)\"",
            "for d in /usr/local /usr/local/etc /usr/local/etc/pam.d;",
        ] + TouchIDSudoDisabler.fallbackPolicyPaths
        for piece in pieces {
            #expect(command.contains(piece), "\(piece)")
        }
        let script = String(command.dropFirst(prefix.count).dropLast())
        #expect(!script.contains("'"), "nothing inside ends the single quotes early")
        #expect(try await PolicyShell.run(script, in: .c, arguments: ["-n"]).status == 0, "valid shell")
    }
}
