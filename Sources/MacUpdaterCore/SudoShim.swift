import Foundation

#if DEBUG
/// `sudo` PATH-shim that transparently injects the `-A` flag.
///
/// Why: `mas upgrade` (and potentially other CLIs we wrap) shells out to
/// `sudo softwareupdate …` when installing Safari extensions and certain
/// MAS apps. `sudo` only honours `SUDO_ASKPASS` when invoked with `-A`, and
/// mas does not pass it. Without a controlling terminal that fails with
/// "sudo: a terminal is required to read the password" — exactly what users
/// see in the Update log.
///
/// The shim is a tiny shell script named `sudo` placed in a private
/// directory prepended to the child process `PATH`. When mas spawns
/// `sudo …`, the kernel resolves *our* `sudo` first, which re-execs
/// `/usr/bin/sudo -A …` and lets the existing askpass helper render the
/// password dialog.
enum SudoShim {
    static let scriptName = "sudo"

    /// `WEGA_SUDO_REAL` is an escape hatch for tests: when set, the shim
    /// delegates to that path instead of `/usr/bin/sudo`. Production code
    /// never sets it, so real sudo is used.
    private static let scriptBody = #"""
    #!/bin/bash
    # Wega Mac Updater — sudo shim.
    # Forces -A so SUDO_ASKPASS is honoured under a GUI session.
    real_sudo="${WEGA_SUDO_REAL:-/usr/bin/sudo}"
    exec "$real_sudo" -A "$@"
    """#

    /// Idempotently writes the shim script into `directory` with mode 0700
    /// and returns the URL of the *directory* (intended to be prepended to
    /// `PATH`, not the script itself).
    @discardableResult
    static func install(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        let script = directory.appendingPathComponent(scriptName)
        let expected = Data(scriptBody.utf8)
        if (try? Data(contentsOf: script)) != expected {
            try expected.write(to: script, options: .atomic)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: script.path
        )
        guard try Data(contentsOf: script) == expected else {
            throw CocoaError(.fileWriteUnknown)
        }
        return directory
    }
}
#endif
