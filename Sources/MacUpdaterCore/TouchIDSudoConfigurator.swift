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
