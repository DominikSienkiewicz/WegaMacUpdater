import Foundation

public enum HomebrewEnvironment {
    public static let processPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Path to the SUDO_ASKPASS helper, if it has been installed. Set once at
    /// app startup via `bootstrapAskpass()`; sudo will then run this script
    /// instead of failing when brew's cask hooks invoke `sudo` from a
    /// terminal-less GUI process.
    public nonisolated(unsafe) static var askpassPath: String?

    /// Directory containing the `sudo` PATH-shim that injects `-A`. Set once
    /// via `bootstrapAskpass()` and prepended to `PATH` so wrapped CLIs that
    /// don't pass `-A` themselves (notably `mas upgrade`) still trigger the
    /// askpass dialog instead of failing on a missing TTY.
    public nonisolated(unsafe) static var sudoShimDirectory: String?

    public static var environment: [String: String] {
        var path = processPath
        if let shim = sudoShimDirectory {
            path = "\(shim):\(path)"
        }
        var env = ["PATH": path]
        if let askpass = askpassPath {
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
        if askpassPath == nil || !FileManager.default.fileExists(atPath: askpassPath ?? "") {
            if let url = try? AskpassHelper.installInApplicationSupport() {
                askpassPath = url.path
            }
        }
        if sudoShimDirectory == nil
            || !FileManager.default.fileExists(atPath: (sudoShimDirectory ?? "") + "/" + SudoShim.scriptName) {
            if let dir = try? SudoShim.installInApplicationSupport() {
                sudoShimDirectory = dir.path
            }
        }
    }
}
