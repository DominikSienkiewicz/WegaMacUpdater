import Foundation

public enum HomebrewEnvironment {
    public static let processPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Path to the SUDO_ASKPASS helper, if it has been installed. Set once at
    /// app startup via `bootstrapAskpass()`; sudo will then run this script
    /// instead of failing when brew's cask hooks invoke `sudo` from a
    /// terminal-less GUI process.
    public nonisolated(unsafe) static var askpassPath: String?

    public static var environment: [String: String] {
        var env = ["PATH": processPath]
        if let askpass = askpassPath {
            env["SUDO_ASKPASS"] = askpass
        }
        return env
    }

    /// Installs the askpass helper and registers its path so subsequent brew
    /// invocations expose it via the environment. Safe to call multiple times.
    /// Failure is swallowed — without askpass, sudo-requiring casks degrade
    /// to the pre-existing "Aktualizacja niekompletna" path, which is no
    /// worse than the status quo.
    public static func bootstrapAskpass() {
        if let existing = askpassPath, FileManager.default.fileExists(atPath: existing) {
            return
        }
        if let url = try? AskpassHelper.installInApplicationSupport() {
            askpassPath = url.path
        }
    }
}
