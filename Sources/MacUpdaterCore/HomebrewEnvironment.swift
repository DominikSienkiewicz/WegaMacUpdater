import Foundation
import WegaHelperKit

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
        /// ARCH-08a: last fully-resolved environment. Populated on the first spawn
        /// and reused verbatim by every later spawn, so the sudo_local read, the
        /// biometry probe and the Mach-O signature verification happen once per
        /// session instead of once per process launch.
        var cachedEnvironment: [String: String]?
        /// Counts cache-miss recomputations. Exposed as a test seam so the
        /// regression can prove a series of spawns computes the environment once.
        var computeCount = 0
    }
    private static let storage = Storage()

    /// Path to the compiled SUDO_ASKPASS helper, if it has been verified. Set via
    /// `bootstrapAskpass()`; sudo will then run this bundle-sealed executable
    /// instead of failing when brew's cask hooks invoke `sudo` from a
    /// terminal-less GUI process.
    static var askpassPath: String? {
        get { storage.lock.withLock { storage.askpassPath } }
        set { storage.lock.withLock { storage.askpassPath = newValue; storage.cachedEnvironment = nil } }
    }

    /// Directory containing the compiled `sudo` PATH-shim that injects `-A`.
    /// Verified via `bootstrapAskpass()` and prepended to `PATH` so wrapped CLIs that
    /// don't pass `-A` themselves (notably `mas upgrade`) still trigger the
    /// askpass dialog instead of failing on a missing TTY.
    static var sudoShimDirectory: String? {
        get { storage.lock.withLock { storage.sudoShimDirectory } }
        set { storage.lock.withLock { storage.sudoShimDirectory = newValue; storage.cachedEnvironment = nil } }
    }

    /// Test seam — when non-nil, `environment` uses this instead of probing
    /// the real `/etc/pam.d/sudo_local` + biometry hardware. Production code
    /// must leave this nil so the live state is consulted the first time the
    /// environment is built (state can flip mid-session when the user enables
    /// Touch ID from InfoView; `invalidateCache()` then drops the cached copy so
    /// the next brew call rebuilds it and immediately respects the new state).
    static var touchIDStateOverride: TouchIDSudoConfigurator.State? {
        get { storage.lock.withLock { storage.touchIDStateOverride } }
        set { storage.lock.withLock { storage.touchIDStateOverride = newValue; storage.cachedEnvironment = nil } }
    }

    /// Test seam (ARCH-08a): number of times `environment` was rebuilt from
    /// scratch. Reused reads never advance it; a cache miss does.
    static var environmentComputeCount: Int {
        get { storage.lock.withLock { storage.computeCount } }
        set { storage.lock.withLock { storage.computeCount = newValue } }
    }

    /// Drops the memoised environment so the next spawn re-reads the live state.
    /// The app calls this whenever it re-checks Touch ID (`TouchIDSetupController`),
    /// which is the one moment the sudo/askpass wiring can change mid-session.
    public static func invalidateCache() {
        storage.lock.withLock { storage.cachedEnvironment = nil }
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
    static func shouldBootstrapAskpass(touchIDState: TouchIDSudoConfigurator.State) -> Bool {
        touchIDState != .enabled
    }

    /// ARCH-08a: environment inherited by every brew/mas child process. The first
    /// spawn resolves it (reading `sudo_local`, probing biometry and verifying the
    /// signed Mach-O helpers); subsequent spawns reuse that result with no disk I/O.
    /// The signature check still runs before the *first* attachment, and the
    /// resolved helpers sit at a root-owned, non-writable path
    /// (`AuthorizationPathTrustValidator`) that a same-user process cannot swap for
    /// the rest of the session — so caching does not lower the trust boundary.
    /// `invalidateCache()` rebuilds it after the only mid-session change (Touch ID
    /// being enabled).
    public static var environment: [String: String] {
        if let cached = storage.lock.withLock({ storage.cachedEnvironment }) {
            return cached
        }
        let computed = resolveEnvironment()
        storage.lock.withLock {
            storage.cachedEnvironment = computed
            storage.computeCount += 1
        }
        return computed
    }

    private static func resolveEnvironment() -> [String: String] {
        let state = touchIDStateOverride ?? TouchIDSudoConfigurator.currentState()
        let useAskpassFallback = shouldBootstrapAskpass(touchIDState: state)

        // Resolve and cryptographically revalidate both Mach-O files before the
        // environment is first attached. The test seam keeps existing unit tests
        // off the real bundle.
        if useAskpassFallback && touchIDStateOverride == nil {
            bootstrapAskpass()
        }

        var path = processPath
        if useAskpassFallback, let shim = sudoShimDirectory {
            path = "\(shim):\(path)"
        }
        var overrides = ["PATH": path]
        if useAskpassFallback, let askpass = askpassPath {
            overrides["SUDO_ASKPASS"] = askpass
        }
        return AuthorizationEnvironment.sanitized(
            inherited: ProcessInfo.processInfo.environment,
            overrides: overrides
        )
    }

    /// Builds the trusted overrides used by the compiled sudo shim. It deliberately ignores
    /// the shim's inherited environment and resolves the root-owned system helper again.
    public static func trustedSudoShimOverrides() -> [String: String] {
        var overrides = ["PATH": processPath]
        if let components = try? AuthorizationComponentResolver().resolveAndVerify() {
            overrides["SUDO_ASKPASS"] = components.askpassExecutable.path
        }
        return overrides
    }

    /// Resolves and verifies the compiled askpass and sudo shim from the system installation.
    /// Failure clears both paths, so no stale or unverified executable remains attached.
    static func bootstrapAskpass() {
        do {
            let components = try AuthorizationComponentResolver().resolveAndVerify()
            askpassPath = components.askpassExecutable.path
            sudoShimDirectory = components.sudoShimDirectory.path
        } catch {
            askpassPath = nil
            sudoShimDirectory = nil
            WegaLog.error(
                .process,
                "Odrzucono komponent autoryzacji sudo: \(error.localizedDescription)"
            )
        }
    }
}
