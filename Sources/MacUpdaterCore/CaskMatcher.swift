import Foundation

public enum CaskMatch: Equatable, Sendable {
    case managed(token: String)
    case candidate(token: String)
    case none
}

public struct CaskMatcher {
    /// Matching structure built **once per scan** and reused for every
    /// application (ARCH-05b). It replaces the previous per-application linear
    /// scan of the whole cask database — and the `String`-per-scalar
    /// normalization it repeated for every app — with O(1) dictionary lookups.
    ///
    /// The only way to obtain an `Index` is `CaskMatcher.makeIndex(...)`, so the
    /// build cost is paid exactly once and cannot silently move back inside the
    /// per-application loop.
    public struct Index: Sendable {
        fileprivate let installedCasks: Set<String>
        fileprivate let normalizedInstalledCasks: [String: String]
        /// Normalized cask token / display name -> cask token. The first cask in
        /// `availableCasks` order wins on collision, preserving the semantics of
        /// the previous `availableCasks.first { … }` lookup.
        fileprivate let tokensByNormalizedName: [String: String]
    }

    private let customMappings: [String: String]

    public init(customMappings: [String: String] = MacUpdaterConstants.customCaskMappings) {
        self.customMappings = customMappings
    }

    public func makeIndex(
        installedCasks: Set<String>,
        availableCasks: some Sequence<BrewCask>
    ) -> Index {
        let normalizedInstalledCasks = installedCasks.reduce(into: [String: String]()) { partial, token in
            partial[StringNormalizer.normalize(token), default: token] = token
        }

        var tokensByNormalizedName: [String: String] = [:]
        for cask in availableCasks {
            let tokenKey = StringNormalizer.normalize(cask.token)
            if tokensByNormalizedName[tokenKey] == nil {
                tokensByNormalizedName[tokenKey] = cask.token
            }
            for displayName in cask.name {
                let nameKey = StringNormalizer.normalize(displayName)
                if tokensByNormalizedName[nameKey] == nil {
                    tokensByNormalizedName[nameKey] = cask.token
                }
            }
        }

        return Index(
            installedCasks: installedCasks,
            normalizedInstalledCasks: normalizedInstalledCasks,
            tokensByNormalizedName: tokensByNormalizedName
        )
    }

    public func match(applicationName: String, using index: Index) -> CaskMatch {
        let normalizedName = StringNormalizer.normalize(applicationName)

        if let installedToken = index.normalizedInstalledCasks[normalizedName] {
            return .managed(token: installedToken)
        }

        let matchedToken = customMappings[applicationName] ?? index.tokensByNormalizedName[normalizedName]

        guard let matchedToken else {
            return .none
        }

        if index.installedCasks.contains(matchedToken) {
            return .managed(token: matchedToken)
        }

        if let installedToken = index.normalizedInstalledCasks[StringNormalizer.normalize(matchedToken)] {
            return .managed(token: installedToken)
        }

        return .candidate(token: matchedToken)
    }

    /// Convenience that builds a throwaway index for a single match. Retained so
    /// existing call sites and tests keep working; scan paths should build one
    /// `Index` via `makeIndex(...)` and reuse it across all applications.
    public func match(
        applicationName: String,
        installedCasks: Set<String>,
        availableCasks: [BrewCask]
    ) -> CaskMatch {
        match(
            applicationName: applicationName,
            using: makeIndex(installedCasks: installedCasks, availableCasks: availableCasks)
        )
    }
}
