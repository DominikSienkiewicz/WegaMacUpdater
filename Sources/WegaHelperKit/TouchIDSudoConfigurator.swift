import Foundation
import LocalAuthentication
import IOKit

/// Detects whether Touch ID is wired into `sudo` (via `pam_tid.so` in
/// `/etc/pam.d/sudo_local`) and exposes a one-shot command to enable it.
///
/// Why `sudo_local`, not `sudo`: starting with macOS Sonoma, Apple ships
/// `/etc/pam.d/sudo_local.template` and the main `sudo` PAM stack
/// `@include`s `sudo_local` first. Edits to `sudo` itself are reverted on
/// every macOS update; edits to `sudo_local` survive.
public enum TouchIDSudoConfigurator {
    public enum State: Equatable, Sendable {
        /// Either Touch ID hardware is absent / disabled, or the PAM module
        /// `pam_tid.so` is not present in this OS.
        case notSupported
        /// Supported, but the user has not yet enabled it for sudo.
        case available
        /// `/etc/pam.d/sudo_local` already contains an active `pam_tid.so`
        /// line — nothing to do.
        case enabled
    }

    public static let pamModulePath = SystemPaths.pamModule
    public static let sudoLocalPath = SystemPaths.sudoLocal

    /// The line we write to `sudo_local`. `sufficient` means: if Touch ID
    /// succeeds, no further auth modules are consulted; if it fails or is
    /// cancelled, sudo falls through to the password prompt (and then to
    /// SUDO_ASKPASS).
    public static let pamDirective = "auth       sufficient     pam_tid.so"

    /// Pure decision function — no I/O. Take the file's current contents
    /// (or nil if it doesn't exist) plus the two capability flags and
    /// classify the state.
    public static func state(
        sudoLocalContents: String?,
        pamModuleExists: Bool,
        biometryAvailable: Bool
    ) -> State {
        guard pamModuleExists, biometryAvailable else { return .notSupported }
        guard let contents = sudoLocalContents else { return .available }
        return containsActiveTouchIDLine(contents) ? .enabled : .available
    }

    /// Whether a line that is not a comment names `auth`, `sufficient` and `pam_tid.so`: the one
    /// detection the card's state and the enable plan share.
    static func containsActiveTouchIDLine(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            return !line.hasPrefix("#") && line.contains("pam_tid.so") && line.contains("sufficient") && line.contains("auth")
        }
    }

    /// Reads the real filesystem + biometry capability to determine state.
    public static func currentState() -> State {
        let contents = try? String(contentsOfFile: sudoLocalPath, encoding: .utf8)
        // DEBT-03: accept any known pam_tid filename, not just the versioned one.
        let pamPresent = SystemPaths.pamModuleCandidates.contains {
            FileManager.default.fileExists(atPath: $0)
        }
        return state(
            sudoLocalContents: contents,
            pamModuleExists: pamPresent,
            biometryAvailable: hasBiometryHardware()
        )
    }

    // MARK: - Root-side writer (privileged helper — FEAT-01)

    /// Pure, idempotent: given the current `sudo_local` (or template, or nil),
    /// return contents that contain the `pam_tid` directive exactly once. No I/O,
    /// so it is unit-tested directly.
    public static func contentsEnablingTouchID(current: String?) -> String {
        var base = current ?? ""
        if containsActiveTouchIDLine(base) { return base } // already enabled — idempotent
        if !base.isEmpty, !base.hasSuffix("\n") { base += "\n" }
        base += pamDirective + "\n"
        return base
    }

    /// The root helper's plan for the bytes it read through the policy directory: `sudo_local`, or
    /// the template when there is none, or nothing. Pure; decided on bytes so nothing read is
    /// re-encoded, and refused rather than replaced when the bytes are not UTF-8 or hold a NUL.
    public static func contentsEnablingTouchID(current: Data) -> TouchIDSudoEnablePlan {
        let bytes = [UInt8](current)
        guard !bytes.contains(0), let text = String(validating: bytes, as: UTF8.self) else { return .refused(.unreadable) }
        guard !containsActiveTouchIDLine(text) else { return .alreadyEnabled }
        var contents = current
        if let last = bytes.last, last != PAMPolicyLines.newline { contents.append(PAMPolicyLines.newline) }
        contents.append(contentsOf: Array((pamDirective + "\n").utf8))
        guard contents.count <= TouchIDSudoDisabler.maximumSize else { return .refused(.tooLarge) }
        return .write(contents)
    }

    /// Pure decision: combine the outcome of an `LAContext` biometry probe
    /// with an IOKit hardware-presence fallback.
    ///
    /// `LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`
    /// answers "can THIS process biometrically authenticate the user *right
    /// now*". On a perfectly Touch-ID-capable Mac that answer goes negative
    /// when the lid is shut (clamshell mode), shortly after boot, or during
    /// the screen-lock grace window — reporting `biometryNotAvailable`, or no
    /// error at all. That transient answer must not hide the sudo+Touch ID
    /// feature, so when `LAContext` is negative *and inconclusive about the
    /// hardware* we fall back to the physical sensor: if it exists, Touch ID
    /// for sudo is genuinely supported and the user must be able to enable it.
    static func biometryAvailable(
        canEvaluate: Bool,
        laErrorCode: Int?,
        sensorPresent: @autoclosure () -> Bool
    ) -> Bool {
        if canEvaluate { return true }
        // `biometryNotEnrolled` / `biometryLockout` already prove the
        // hardware is present — the user just hasn't registered a finger,
        // or is temporarily locked out.
        if let code = laErrorCode,
           code == LAError.biometryNotEnrolled.rawValue ||
           code == LAError.biometryLockout.rawValue {
            return true
        }
        // Any other negative answer (`biometryNotAvailable`, or no error at
        // all) is inconclusive about the *hardware* — consult IOKit directly.
        return sensorPresent()
    }

    private static func hasBiometryHardware() -> Bool {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)
        return biometryAvailable(
            canEvaluate: canEvaluate,
            laErrorCode: error?.code,
            sensorPresent: touchIDSensorPresent()
        )
    }

    /// Stable hardware probe: is a physical Touch ID sensor present in the
    /// IORegistry? Unlike `LAContext`, this does not depend on the calling
    /// process, its code signature, the lid state, or how recently the Mac
    /// booted — so it is a reliable answer to "does this Mac have Touch ID".
    private static func touchIDSensorPresent() -> Bool {
        for serviceName in ["AppleBiometricSensor", "AppleMesaSEPDriver"] {
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching(serviceName)
            )
            if service != 0 {
                IOObjectRelease(service)
                return true
            }
        }
        return false
    }

    /// Retained as an internal compatibility seam for the pre-SEC-05 regression tests.
    /// Production no longer executes shell text as root; it uses the bounded XPC method.
    static let enableShellCommand: String = """
    /bin/sh -c '\
    set -e; \
    tmp="$(/usr/bin/mktemp)"; \
    if [ -r /etc/pam.d/sudo_local ]; then /bin/cat /etc/pam.d/sudo_local > "$tmp"; \
    elif [ -r /etc/pam.d/sudo_local.template ]; then /bin/cat /etc/pam.d/sudo_local.template > "$tmp"; \
    fi; \
    if ! /usr/bin/grep -E "^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\\.so" "$tmp" >/dev/null 2>&1; then \
    /bin/echo "auth       sufficient     pam_tid.so" >> "$tmp"; \
    fi; \
    /usr/bin/tee /etc/pam.d/sudo_local < "$tmp" >/dev/null; \
    /bin/chmod 0644 /etc/pam.d/sudo_local; \
    /usr/sbin/chown root:wheel /etc/pam.d/sudo_local; \
    /bin/rm -f "$tmp"'
    """

    /// Copy-pasteable fallback for Terminal.app. It performs backup, stages the new
    /// contents in the PAM directory, atomically renames them into place, verifies
    /// the bytes, and rolls back on failure. The grep accepts only active directives.
    ///
    /// It runs `/usr/bin/sudo`, not the first `sudo` on the user's `PATH` (Z2), in the C locale. Its
    /// output keeps every line already there, so it refuses first, before it creates anything, a
    /// `sudo_local` that is a link, not a regular file, not root's, writable by group or other (Z1) or
    /// with an ACL (M1): such a file must not end up as root's own. When there is no `sudo_local`, the template is
    /// the base, so the same goes for a template that is a link, not a regular file, not root's,
    /// writable by group or other or with an ACL (I1); a missing template gives an empty base. It ends
    /// an unterminated last line before it adds the directive.
    public static let manualEnableTerminalCommand: String = "/usr/bin/sudo /bin/sh -c '" + manualEnableShellScript(
        target: SystemPaths.sudoLocal, stagingDirectory: SystemPaths.pamPolicyDisplayDirectory,
        template: SystemPaths.sudoLocalTemplate, requiredOwnerUID: 0, ownership: "root:wheel"
    ) + "'"

    /// The script behind `manualEnableTerminalCommand`, with its paths, the owner `sudo_local` must
    /// have and the owner it gives the result as parameters, so tests run it on temporary files
    /// without `sudo` (`ownership: nil` leaves out `chown`). The paths go in as plain words.
    static func manualEnableShellScript(
        target: String, stagingDirectory: String, template: String, requiredOwnerUID: UInt32, ownership: String?
    ) -> String {
        let temporary = stagingDirectory + "/" + TouchIDSudoDisabler.swapNamePrefix
        let chown = ownership.map { #" /usr/sbin/chown \#($0) "$staged";"# } ?? ""
        return [
            #"set -eu; export LC_ALL=C; target=\#(target); template=\#(template);"#,
            #"if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then"#,
            #"echo "Wega: sudo_local is not a regular file; nothing changed." >&2; exit 1; fi;"#,
            #"if [ -e "$target" ]; then owner=$(/usr/bin/stat -f %u "$target"); mode=$(/usr/bin/stat -f %Lp "$target");"#,
            #"if [ "$owner" -ne \#(requiredOwnerUID) ] || [ $(( 0$mode & 022 )) -ne 0 ]"#,
            #"|| /bin/ls -lde "$target" | /usr/bin/grep -q "^ [0-9][0-9]*: "; then"#,
            #"echo "Wega: someone other than root can change sudo_local; nothing changed." >&2; exit 1; fi; fi;"#,
            #"if [ ! -e "$target" ] && { [ -e "$template" ] || [ -L "$template" ]; }; then"#,
            #"if [ -L "$template" ] || [ ! -f "$template" ]; then"#,
            #"echo "Wega: sudo_local.template is not a regular file; nothing changed." >&2; exit 1; fi;"#,
            #"towner=$(/usr/bin/stat -f %u "$template"); tmode=$(/usr/bin/stat -f %Lp "$template");"#,
            #"if [ "$towner" -ne \#(requiredOwnerUID) ] || [ $(( 0$tmode & 022 )) -ne 0 ]"#,
            #"|| /bin/ls -lde "$template" | /usr/bin/grep -q "^ [0-9][0-9]*: "; then"#,
            #"echo "Wega: someone other than root can change sudo_local.template; nothing changed." >&2; exit 1; fi; fi;"#,
            #"backup=$(/usr/bin/mktemp \#(temporary)backup.XXXXXX);"#,
            #"staged=$(/usr/bin/mktemp \#(temporary)new.XXXXXX);"#,
            #"check=$(/usr/bin/mktemp \#(temporary)check.XXXXXX); had=0;"#,
            #"if [ -e "$target" ]; then /bin/cp -p "$target" "$backup";"#,
            #"/bin/cat "$target" > "$staged"; had=1;"#,
            #"elif [ -f "$template" ] && [ ! -L "$template" ]; then"#,
            #"/bin/cat "$template" > "$staged"; fi;"#,
            #"if ! /usr/bin/grep -E "^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\\.so""#,
            #" "$staged" >/dev/null 2>&1; then"#,
            #"if [ -n "$(/usr/bin/tail -c 1 "$staged")" ]; then /bin/echo >> "$staged"; fi;"#,
            #"/bin/echo "\#(pamDirective)" >> "$staged"; fi;"#,
            #"/bin/chmod 0644 "$staged";"# + chown,
            #"/bin/cp "$staged" "$check"; rollback() {"#,
            #"if [ "$had" -eq 1 ]; then /bin/mv -f "$backup" "$target";"#,
            #"else /bin/rm -f "$target"; fi; /bin/rm -f "$staged" "$check"; };"#,
            #"if ! /bin/mv -f "$staged" "$target"; then rollback; exit 1; fi;"#,
            #"if ! /usr/bin/cmp -s "$target" "$check"; then rollback; exit 1; fi;"#,
            #"/bin/rm -f "$backup" "$check""#,
        ].joined(separator: " ")
    }

    /// The command the Touch ID card offers to turn Touch ID for `sudo` off when the helper cannot
    /// (Aneks E.6, E.9): the reviewed script, one line, through `/usr/bin/sudo` so no `sudo` earlier
    /// on the user's `PATH` sees the password (Z2).
    public static let manualDisableTerminalCommand = "/usr/bin/sudo /bin/sh -c '" + disableShellScript(
        target: SystemPaths.sudoLocal, stagingDirectory: SystemPaths.pamPolicyDisplayDirectory,
        fallbackPaths: TouchIDSudoDisabler.fallbackPolicyPaths,
        localDirectories: ["/usr/local", "/usr/local/etc", "/usr/local/etc/pam.d"], ownership: "root:wheel"
    ) + "'"

    /// The script behind `manualDisableTerminalCommand`. It applies the helper's content rules again
    /// when it runs, in the C locale so `[[:space:]]` is the helper's set of blanks (RC2-5): a regular
    /// file, at most `TouchIDSudoDisabler.maximumSize` bytes, no NUL, UTF-8, at least one line that is
    /// exactly the directive, no backslash, and nothing else active. It also refuses a link in the
    /// `/usr/local` chain (Z3) and any later policy file that exists. Only then does it write the file
    /// without the directive beside the original and rename it into place; a trap removes that new
    /// file on any failure.
    ///
    /// The paths are inserted as they are, so they must be plain words with no space or quote. Tests
    /// pass temporary ones and `ownership: nil`, which leaves `chown` out.
    static func disableShellScript(
        target: String, stagingDirectory: String, fallbackPaths: [String], localDirectories: [String], ownership: String?
    ) -> String {
        let staged = stagingDirectory + "/" + TouchIDSudoDisabler.swapNamePrefix + "new.XXXXXX"
        let chown = ownership.map { #"/usr/sbin/chown \#($0) "$staged"; "# } ?? ""
        return [
            #"set -eu; export LC_ALL=C; target=\#(target); line="\#(pamDirective)"; staged="";"#,
            #"trap "/bin/rm -f \"\$staged\"" EXIT;"#,
            #"if [ ! -f "$target" ] || [ -L "$target" ]; then echo "Wega: sudo_local is not a regular file; nothing changed." >&2; exit 1; fi;"#,
            #"if [ "$(/usr/bin/stat -f %z "$target")" -gt \#(TouchIDSudoDisabler.maximumSize) ]; then echo "Wega: sudo_local is too large; nothing changed." >&2; exit 1; fi;"#,
            #"if ! /usr/bin/tr -d "\000" < "$target" | /usr/bin/cmp -s - "$target"; then echo "Wega: sudo_local contains a NUL byte; nothing changed." >&2; exit 1; fi;"#,
            #"if ! /usr/bin/iconv -f UTF-8 -t UTF-8 "$target" > /dev/null 2>&1; then echo "Wega: sudo_local is not UTF-8; nothing changed." >&2; exit 1; fi;"#,
            #"if ! /usr/bin/grep -q -x -F "$line" "$target"; then echo "Wega: no exact pam_tid line; nothing changed."; exit 0; fi;"#,
            #"if /usr/bin/grep -q -F "\\" "$target"; then echo "Wega: sudo_local contains a backslash; nothing changed." >&2; exit 1; fi;"#,
            #"if /usr/bin/grep -v -x -F "$line" "$target" | /usr/bin/grep -q -v -E "^[[:space:]]*(#|$)"; then echo "Wega: sudo_local has other settings; nothing changed." >&2; exit 1; fi;"#,
            #"for d in \#(localDirectories.joined(separator: " ")); do if [ -L "$d" ]; then echo "Wega: $d is a link; nothing changed." >&2; exit 1; fi; done;"#,
            #"for p in \#(fallbackPaths.joined(separator: " ")); do"#,
            #"if [ -e "$p" ] || [ -L "$p" ]; then echo "Wega: $p exists; nothing changed." >&2; exit 1; fi; done;"#,
            #"staged=$(/usr/bin/mktemp \#(staged));"#,
            #"/usr/bin/grep -v -x -F "$line" "$target" > "$staged" || [ $? -eq 1 ];"#,
            chown + #"/bin/chmod 0644 "$staged";"#,
            #"/bin/mv -f "$staged" "$target"; echo "Wega: Touch ID for sudo is off. Check: sudo -k; sudo true""#,
        ].joined(separator: " ")
    }
}

/// Classified result of attempting to enable Touch ID for sudo via the
/// osascript-elevated `enableShellCommand`. The split exists so the UI can
/// distinguish three meaningfully-different states:
///
/// - `.cancelledByUser` — silent, stay in `.available`, no error UI.
/// - `.permissionDenied` — TCC blocked the write even at root. Show the
///   manual Terminal command + "Otwórz Terminal" button instead of a raw
///   stderr blob.
/// - `.otherError` — genuine unexpected failure; surface stderr verbatim.
enum TouchIDSudoEnableOutcome: Equatable, Sendable {
    case success
    case cancelledByUser
    case permissionDenied
    case otherError(String)

    public static func classify(exitCode: Int32, stderr: String) -> TouchIDSudoEnableOutcome {
        if exitCode == 0 { return .success }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // osascript localises the cancel message ("User canceled.",
        // "Anulowano przez użytkownika", …) but they all contain a "cancel"
        // root in English builds; the AppleScript error code is the same
        // (-128) regardless of locale, but it shows up in stderr only when
        // osascript echoes the underlying error text.
        if stderr.localizedCaseInsensitiveContains("cancel") {
            return .cancelledByUser
        }
        if stderr.contains("Operation not permitted") {
            return .permissionDenied
        }
        return .otherError(trimmed)
    }
}
