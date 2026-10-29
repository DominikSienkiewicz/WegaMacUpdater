import Foundation

/// Which brew command "Aktualizuj przez Brew" runs for a cask row.
///
/// `install --cask --force` is the adoption: it takes over a bundle Homebrew did not install
/// and moves it to the cask's version. It is a no-op, though, whenever Homebrew's Caskroom
/// record already names that version — brew answers "Not upgrading …, the latest version is
/// already installed" and writes nothing, whatever the bundle on disk says. That is exactly
/// the state an app's own updater leaves behind when it puts an older build back over a brew
/// install (Discord's Squirrel feed does this while it lags the cask), and the state a REL-07
/// rollback leaves too. `reinstall` rebuilds the record and the app together, so it is the
/// command for that case — chosen up front instead of after a wasted run and a banner asking
/// the user to type it.
public enum CaskAdoptionCommand {
    /// - Parameters:
    ///   - offeredVersion: the version the row offers — the cask's `version` string.
    ///   - recordedVersion: the version Homebrew's Caskroom records for `token`, `nil` when
    ///     Homebrew tracks no install of it.
    /// - Returns: `reinstall` arguments when the record already equals the offer, otherwise
    ///   the adoption's `install --force` arguments.
    ///
    /// Compared as exact strings on purpose: Homebrew's own "already installed" check compares
    /// its recorded version string with the cask's, so a tolerant comparison would predict a
    /// no-op that brew does not perform.
    public static func arguments(token: String, offeredVersion: String?, recordedVersion: String?) -> [String] {
        guard let offeredVersion, let recordedVersion, offeredVersion == recordedVersion else {
            return BrewService.adoptCaskArguments(token: token)
        }
        return BrewService.reinstallCaskArguments(token: token)
    }
}
