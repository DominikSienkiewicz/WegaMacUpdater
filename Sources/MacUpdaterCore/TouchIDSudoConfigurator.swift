import Foundation
import LocalAuthentication

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

    public static let pamModulePath = "/usr/lib/pam/pam_tid.so.2"
    public static let sudoLocalPath = "/etc/pam.d/sudo_local"

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
        return state(
            sudoLocalContents: contents,
            pamModuleExists: FileManager.default.fileExists(atPath: pamModulePath),
            biometryAvailable: hasBiometryHardware()
        )
    }

    private static func hasBiometryHardware() -> Bool {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if canEvaluate { return true }
        // `biometryNotEnrolled` still means the hardware is present —
        // the user just hasn't registered a finger. We treat that the
        // same as "available", because enabling sudo+TouchID makes sense
        // even before enrolment (it'll work the moment a finger is added).
        if let code = error?.code,
           code == LAError.biometryNotEnrolled.rawValue ||
           code == LAError.biometryLockout.rawValue {
            return true
        }
        return false
    }

    /// One-line shell command suitable for `osascript -e "do shell script ...
    /// with administrator privileges"`. Idempotent: re-running on an
    /// already-enabled file just rewrites the same content. Uses a temp file
    /// + `mv` so the directive is atomically present (no half-written state).
    public static let enableShellCommand: String = """
    /bin/sh -c '\
    set -e; \
    tmp="$(/usr/bin/mktemp)"; \
    if [ -r /etc/pam.d/sudo_local ]; then /bin/cat /etc/pam.d/sudo_local > "$tmp"; \
    elif [ -r /etc/pam.d/sudo_local.template ]; then /bin/cat /etc/pam.d/sudo_local.template > "$tmp"; \
    fi; \
    if ! /usr/bin/grep -E "^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\\.so" "$tmp" >/dev/null 2>&1; then \
    /bin/echo "auth       sufficient     pam_tid.so" >> "$tmp"; \
    fi; \
    /bin/chmod 0644 "$tmp"; \
    /usr/sbin/chown root:wheel "$tmp"; \
    /bin/mv "$tmp" /etc/pam.d/sudo_local'
    """
}
