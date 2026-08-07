import Foundation

/// Single source of truth for the fixed macOS system paths Wega depends on —
/// binaries it shells out to (`sudo`, `pgrep`, …), Homebrew/mas/npm install
/// locations, the PAM files Touch ID configuration touches, and fixed
/// filesystem roots.
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
    // MARK: Filesystem roots

    /// The root of the startup volume.
    public static let fileSystemRoot = URL(fileURLWithPath: "/", isDirectory: true)

    /// The system-wide `/Applications` directory.
    public static let applicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Root-owned Application Support used by privileged Wega components.
    public static let systemApplicationSupportDirectory = URL(
        fileURLWithPath: "/Library/Application Support",
        isDirectory: true
    )

    /// Where macOS JDK installers place their `.jdk` bundles. Not an application
    /// directory, so `AppScanDirectories` never reaches it — see ``JavaRuntimeScanner``.
    public static let javaVirtualMachinesDirectory = URL(
        fileURLWithPath: "/Library/Java/JavaVirtualMachines",
        isDirectory: true
    )

    /// Creative Cloud's own record of every installed Adobe product: one `.adbarg`
    /// argument file per product, naming its SAP code and installed version.
    public static let adobeUninstallDirectory = URL(
        fileURLWithPath: "/Library/Application Support/Adobe/Uninstall",
        isDirectory: true
    )

    /// Prefix macOS uses for the physical targets of its root directory aliases.
    public static let privateDirectoryPrefix = "/private"

    /// Root directories whose physical paths live below `/private` on macOS.
    public static let privateRootAliases = ["/tmp", "/var", "/etc"]

    // MARK: System binaries

    public static let sudo = URL(fileURLWithPath: "/usr/bin/sudo")
    public static let posixShell = URL(fileURLWithPath: "/bin/sh")
    public static let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
    public static let kill = URL(fileURLWithPath: "/bin/kill")
    public static let killall = URL(fileURLWithPath: "/usr/bin/killall")
    public static let open = URL(fileURLWithPath: "/usr/bin/open")
    public static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    public static let pkgutil = URL(fileURLWithPath: "/usr/sbin/pkgutil")

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

    /// DEBT-03: candidate module filenames across macOS versions. The versioned
    /// `.so.2` is current; the unversioned name is a fallback so capability
    /// detection doesn't yield a false "notSupported" if Apple renames it.
    public static let pamModuleCandidates = [
        "/usr/lib/pam/pam_tid.so.2",
        "/usr/lib/pam/pam_tid.so",
    ]

    /// The drop-in PAM file whose edits survive macOS updates.
    public static let sudoLocal = "/etc/pam.d/sudo_local"

    /// Apple-shipped template for `sudo_local` (Sonoma+); seed content when the
    /// drop-in file doesn't exist yet.
    public static let sudoLocalTemplate = "/etc/pam.d/sudo_local.template"
}
