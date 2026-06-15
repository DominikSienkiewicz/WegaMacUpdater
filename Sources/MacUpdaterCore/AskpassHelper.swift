import Foundation

/// Writes a tiny shell script that satisfies sudo's `SUDO_ASKPASS` contract:
/// when sudo runs without a controlling terminal and `SUDO_ASKPASS` points at
/// an executable, sudo invokes that program and reads the password from its
/// stdout. The script delegates to `osascript`, which renders a native macOS
/// secure-input dialog from any GUI process (including Wega).
///
/// Without this, brew's cask uninstall hooks (`sudo launchctl …`,
/// `sudo pkgutil --forget …`) fail when Wega runs from the Finder/Dock — see
/// the Zoom upgrade case in [BrewUpgradeOutcomeTests].
public enum AskpassHelper {
    public static let scriptName = "askpass.sh"

    /// AppleScript dialog. The first prompt the user sees comes from the cask
    /// itself (e.g. "Removing launchctl service us.zoom.ZoomDaemon") — keep
    /// the wording generic so we don't lie about which exact privileged
    /// operation is being authorised.
    private static let scriptBody = #"""
    #!/bin/bash
    # Wega Mac Updater — sudo askpass helper (fallback ostatniej szansy).
    # PREFEROWANĄ ścieżką jest Touch ID (pam_tid w /etc/pam.d/sudo_local) — patrz
    # TouchIDSudoConfigurator. Ten dialog pojawia się TYLKO gdy Touch ID jest
    # wyłączony, a brew (bez TTY) wywołuje wewnętrznie sudo (SEC-01).
    # Świadomie NIE używamy `tell application "System Events"`: `display dialog`
    # ze StandardAdditions nie wymaga uprawnień Automation/TCC pod Hardened
    # Runtime (SEC-07 / D3).
    osascript <<'APPLESCRIPT'
    display dialog "Homebrew prosi o hasło administratora, żeby dokończyć aktualizację (np. zarejestrować/odpiąć usługi launchctl albo pkgutil)." with title "Wega Mac Updater" default answer "" with hidden answer with icon caution buttons {"Anuluj", "OK"} default button "OK"
    return text returned of result
    APPLESCRIPT
    """#

    /// Idempotently writes the script into `directory` with mode 0700.
    /// Returns the absolute file URL of the installed script.
    @discardableResult
    public static func install(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(scriptName)
        try Data(scriptBody.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
        return url
    }

    /// Default install location: `~/Library/Application Support/WegaMacUpdater/`.
    /// Returns the URL of the installed script (creating it on first call).
    @discardableResult
    public static func installInApplicationSupport() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("WegaMacUpdater", isDirectory: true)
        return try install(in: support)
    }
}
