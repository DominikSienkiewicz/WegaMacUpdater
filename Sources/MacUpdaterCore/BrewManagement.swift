import Foundation

/// Decides whether Homebrew's `outdated` is the authoritative update source for an
/// installed app, or whether detection should fall through to the cask-version check
/// (cask-DB latest vs on-disk bundle version).
///
/// Brew is authoritative ONLY when it actually tracks an installed version for the
/// cask. A cask that `brew list --cask` reports but `brew info --installed` has no
/// version for — empty Caskroom metadata, which happens to self-updating casks like
/// **Claude** and **Postman** whose bundle was replaced out-of-band — is invisible to
/// `brew outdated`. Deferring to brew there hides the update entirely; instead the app
/// must be treated as an adoption candidate so the cask-version check can surface it.
public enum BrewManagement {
    /// - Parameters:
    ///   - caskToken: the app's resolved cask token, if any.
    ///   - isManagedByBrew: scanner's verdict (set when the app name maps to an installed cask).
    ///   - installedCaskTokens: every token from `brew list --cask`.
    ///   - brewTrackedTokens: tokens for which brew knows an installed version (`brew info --installed`).
    public static func isAuthoritative(
        caskToken: String?,
        isManagedByBrew: Bool,
        installedCaskTokens: Set<String>,
        brewTrackedTokens: Set<String>
    ) -> Bool {
        guard let token = caskToken else { return isManagedByBrew }
        let normalized = StringNormalizer.normalize(token)

        let listed = isManagedByBrew
            || installedCaskTokens.contains { StringNormalizer.normalize($0) == normalized }
        guard listed else { return false }

        // Listed, but is brew able to report on it? Only if it tracks a version.
        return brewTrackedTokens.contains { StringNormalizer.normalize($0) == normalized }
    }
}
