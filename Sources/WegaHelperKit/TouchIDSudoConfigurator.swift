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

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.contains("pam_tid.so") &&
               line.contains("sufficient") &&
               line.contains("auth") {
                return .enabled
            }
        }
        return .available
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
        for rawLine in base.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.contains("pam_tid.so"), line.contains("sufficient"), line.contains("auth") {
                return base // already enabled — idempotent
            }
        }
        if !base.isEmpty, !base.hasSuffix("\n") { base += "\n" }
        base += pamDirective + "\n"
        return base
    }

    /// Writes `sudo_local` as root through a backup → atomic write → readback
    /// transaction. Any failure restores the original bytes and metadata; a failed
    /// restoration is surfaced explicitly instead of leaving a partially written PAM stack.
    public static func writeSudoLocalEnablingTouchID() throws {
        let current = (try? String(contentsOfFile: sudoLocalPath, encoding: .utf8))
            ?? (try? String(contentsOfFile: SystemPaths.sudoLocalTemplate, encoding: .utf8))
        let contents = contentsEnablingTouchID(current: current)
        let url = URL(fileURLWithPath: sudoLocalPath)
        try SudoLocalTransactionalWriter().writeAtomically(Data(contents.utf8), to: url)
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
    public static let manualEnableTerminalCommand: String = [
        #"sudo /bin/sh -c 'set -eu; target=/etc/pam.d/sudo_local;"#,
        #"backup=$(/usr/bin/mktemp /etc/pam.d/.sudo_local.wega-backup.XXXXXX);"#,
        #"staged=$(/usr/bin/mktemp /etc/pam.d/.sudo_local.wega-new.XXXXXX);"#,
        #"check=$(/usr/bin/mktemp /etc/pam.d/.sudo_local.wega-check.XXXXXX); had=0;"#,
        #"if [ -e "$target" ]; then /bin/cp -p "$target" "$backup";"#,
        #"/bin/cat "$target" > "$staged"; had=1;"#,
        #"elif [ -r /etc/pam.d/sudo_local.template ]; then"#,
        #"/bin/cat /etc/pam.d/sudo_local.template > "$staged"; fi;"#,
        #"if ! /usr/bin/grep -E "^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\\.so""#,
        #" "$staged" >/dev/null 2>&1; then"#,
        #"/bin/echo "auth       sufficient     pam_tid.so" >> "$staged"; fi;"#,
        #"/bin/chmod 0644 "$staged"; /usr/sbin/chown root:wheel "$staged";"#,
        #"/bin/cp "$staged" "$check"; rollback() {"#,
        #"if [ "$had" -eq 1 ]; then /bin/mv -f "$backup" "$target";"#,
        #"else /bin/rm -f "$target"; fi; /bin/rm -f "$staged" "$check"; };"#,
        #"if ! /bin/mv -f "$staged" "$target"; then rollback; exit 1; fi;"#,
        #"if ! /usr/bin/cmp -s "$target" "$check"; then rollback; exit 1; fi;"#,
        #"/bin/rm -f "$backup" "$check"'"#
    ].joined(separator: " ")
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
