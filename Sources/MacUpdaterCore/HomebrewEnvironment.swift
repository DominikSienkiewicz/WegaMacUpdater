import Foundation

public enum HomebrewEnvironment {
    public static let processPath = SystemPaths.homebrewProcessPath

    /// DEBT-04: shared process-wide state lives behind a lock instead of
    /// `nonisolated(unsafe)` (which silenced Swift 6 concurrency checking). The
    /// public surface is unchanged — `static var` get/set forwards to the holder.
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var askpassPath: String?
        var sudoShimDirectory: String?
        var touchIDStateOverride: TouchIDSudoConfigurator.State?
    }
    private static let storage = Storage()

    /// Path to the SUDO_ASKPASS helper, if it has been installed. Set once at
    /// app startup via `bootstrapAskpass()`; sudo will then run this script
    /// instead of failing when brew's cask hooks invoke `sudo` from a
    /// terminal-less GUI process.
    public static var askpassPath: String? {
        get { storage.lock.withLock { storage.askpassPath } }
        set { storage.lock.withLock { storage.askpassPath = newValue } }
    }

    /// Directory containing the `sudo` PATH-shim that injects `-A`. Set once
    /// via `bootstrapAskpass()` and prepended to `PATH` so wrapped CLIs that
    /// don't pass `-A` themselves (notably `mas upgrade`) still trigger the
    /// askpass dialog instead of failing on a missing TTY.
    public static var sudoShimDirectory: String? {
        get { storage.lock.withLock { storage.sudoShimDirectory } }
        set { storage.lock.withLock { storage.sudoShimDirectory = newValue } }
    }

    /// Test seam — when non-nil, `environment` uses this instead of probing
    /// the real `/etc/pam.d/sudo_local` + biometry hardware. Production code
    /// must leave this nil so the live state is consulted on every read
    /// (state can flip mid-session when the user enables Touch ID from
    /// InfoView, and the next brew call must immediately respect that).
    public static var touchIDStateOverride: TouchIDSudoConfigurator.State? {
        get { storage.lock.withLock { storage.touchIDStateOverride } }
        set { storage.lock.withLock { storage.touchIDStateOverride = newValue } }
    }

    /// Why this is dynamic, not bootstrap-time: the sudo shim doesn't merely
    /// "force -A so SUDO_ASKPASS works" — it actively *prevents* `pam_tid.so`
    /// from prompting biometrically. So when Touch ID is wired into
    /// `sudo_local`, gating the shim off lets sudo go through PAM naturally:
    /// pam_tid pops the Touch ID sheet, succeeds, sudo accepts, no askpass
    /// password dialog. When Touch ID is NOT enabled, the shim + SUDO_ASKPASS
    /// remain the only way brew's cask hooks (Zoom, Parallels, kext
    /// installers) can authenticate without a controlling terminal.
    /// Whether the askpass helper and the sudo shim are needed at all. With Touch ID wired
    /// into `sudo_local` they are not merely redundant — the shim would suppress the
    /// biometric prompt — so we neither install nor reference them.
    public static func shouldBootstrapAskpass(touchIDState: TouchIDSudoConfigurator.State) -> Bool {
        touchIDState != .enabled
    }

    public static var environment: [String: String] {
        let state = touchIDStateOverride ?? TouchIDSudoConfigurator.currentState()
        let useAskpassFallback = shouldBootstrapAskpass(touchIDState: state)

        // M3(c) — install the helper files here, on the way to spawning brew, rather than
        // at app launch. A user who opens Wega to look around never gets a `sudo` shim
        // written into Application Support behind their back. Only the real thing does:
        // the test seam (`touchIDStateOverride`) marks a unit test, which must not touch disk.
        if useAskpassFallback && touchIDStateOverride == nil {
            bootstrapAskpass()
        }

        var path = processPath
        if useAskpassFallback, let shim = sudoShimDirectory {
            path = "\(shim):\(path)"
        }
        var env = ["PATH": path]
        if useAskpassFallback, let askpass = askpassPath {
            env["SUDO_ASKPASS"] = askpass
        }
        return env
    }

    /// Installs the askpass helper and the sudo PATH-shim, registering both
    /// so subsequent brew/mas invocations pick them up via the environment.
    /// Safe to call multiple times. Failure is swallowed — without askpass
    /// the sudo-requiring path degrades to the pre-existing "Aktualizacja
    /// niekompletna" surface, which is no worse than the status quo.
    public static func bootstrapAskpass() {
        if askpassPath == nil || !FileManager.default.fileExists(atPath: askpassPath ?? ""),
           let url = try? AskpassHelper.installInApplicationSupport() {
            askpassPath = url.path
        }
        if sudoShimDirectory == nil
            || !FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: sudoShimDirectory ?? "")
                    .appendingPathComponent(SudoShim.scriptName).path),
           let dir = try? SudoShim.installInApplicationSupport() {
            sudoShimDirectory = dir.path
        }
    }
}
