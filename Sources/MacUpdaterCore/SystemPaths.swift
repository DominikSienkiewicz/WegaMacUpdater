import Foundation

/// Single source of truth for the fixed macOS system paths Wega depends on —
/// binaries it shells out to (`sudo`, `pgrep`, …), Homebrew/mas/npm install
/// locations, the PAM files Touch ID configuration touches, and the
/// `/Applications` scan roots.
///
/// These are deliberately hard-coded: they are dictated by macOS and Homebrew,
/// not by Wega, and must not be sourced from a writable config (routing
/// `/usr/bin/sudo` through a user-editable file would be a privilege-escalation
/// vector). Centralizing them here keeps every absolute-path literal in one
/// auditable place instead of scattered across a dozen call sites — and lets
/// the project carve out this single file from SonarCloud's S1075
/// ("URI should not be hard-coded") rule, which by design cannot fire on system
/// paths that have no customizable alternative.
public enum SystemPaths {
    // MARK: Scan roots

    /// The system-wide `/Applications` directory.
    public static let applicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)

    // MARK: System binaries

    public static let sudo = URL(fileURLWithPath: "/usr/bin/sudo")
    public static let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
    public static let killall = URL(fileURLWithPath: "/usr/bin/killall")
    public static let open = URL(fileURLWithPath: "/usr/bin/open")
    public static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")

    /// Login shell used when `$SHELL` is unset.
    public static let defaultLoginShell = "/bin/zsh"

    // MARK: Homebrew

    /// `PATH` exported to brew/mas subprocesses so they resolve their own tools.
    public static let homebrewProcessPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// `brew` install locations, Apple-silicon first then Intel.
    public static let brewCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
        URL(fileURLWithPath: "/usr/local/bin/brew"),
    ]

    /// `mas` install locations, Apple-silicon first then Intel.
    public static let masCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/mas"),
        URL(fileURLWithPath: "/usr/local/bin/mas"),
    ]

    /// `npm` install locations, Apple-silicon first then Intel.
    public static let npmCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/npm"),
        URL(fileURLWithPath: "/usr/local/bin/npm"),
    ]

    // MARK: Touch ID / sudo PAM

    /// The `pam_tid.so` module shipped by recent macOS.
    public static let pamModule = "/usr/lib/pam/pam_tid.so.2"

    /// The drop-in PAM file whose edits survive macOS updates.
    public static let sudoLocal = "/etc/pam.d/sudo_local"

    /// Apple-shipped template for `sudo_local` (Sonoma+); seed content when the
    /// drop-in file doesn't exist yet.
    public static let sudoLocalTemplate = "/etc/pam.d/sudo_local.template"
}
