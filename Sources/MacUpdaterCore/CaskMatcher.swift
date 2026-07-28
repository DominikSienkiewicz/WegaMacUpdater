import Foundation

/// **How** a `.app` was tied to a cask token.
///
/// LT-03 — this used to be computed inside `CaskMatcher.match` and thrown away: `CaskMatch`
/// carried only the token, so no caller could answer a question the matcher had already
/// answered. `CaskMatchScorer` asks exactly that question — its curated-mapping and
/// display-name signals are *about the route*, not about the strings — and with the route
/// gone, both call sites could only pass literals, and both signals were dead.
///
/// Ordered strongest first, which is also the order `match` tries them in.
public enum CaskMatchProvenance: Equatable, Sendable {
    /// The app's name normalized straight onto a cask that is already installed.
    case installedToken
    /// An explicit entry in `customCaskMappings` — a human saying this app *is* this cask.
    case curatedMapping
    /// The app's name normalized onto a cask token in the catalog.
    case token
    /// The app's name normalized onto one of a cask's display names.
    case displayName
}

public enum CaskMatch: Equatable, Sendable {
    case managed(token: String, provenance: CaskMatchProvenance)
    case candidate(token: String, provenance: CaskMatchProvenance)
    case none

    /// The route taken, or `nil` when there was no match to take one.
    public var provenance: CaskMatchProvenance? {
        switch self {
        case let .managed(_, provenance):   return provenance
        case let .candidate(_, provenance): return provenance
        case .none:                         return nil
        }
    }

    public var token: String? {
        switch self {
        case let .managed(token, _):   return token
        case let .candidate(token, _): return token
        case .none:                    return nil
        }
    }
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
        /// Normalized cask token / display name -> the cask token **and which of the two
        /// it was**. The first cask in `availableCasks` order wins on collision, preserving
        /// the semantics of the previous `availableCasks.first { … }` lookup.
        ///
        /// LT-03 — tokens and display names share one lookup, so the route has to be stored
        /// with the hit; it cannot be recovered afterwards by asking the index again.
        fileprivate let tokensByNormalizedName: [String: IndexedToken]
    }

    fileprivate struct IndexedToken: Sendable {
        let token: String
        let provenance: CaskMatchProvenance
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

        var tokensByNormalizedName: [String: IndexedToken] = [:]
        for cask in availableCasks {
            let tokenKey = StringNormalizer.normalize(cask.token)
            if tokensByNormalizedName[tokenKey] == nil {
                tokensByNormalizedName[tokenKey] = IndexedToken(token: cask.token, provenance: .token)
            }
            for displayName in cask.name {
                let nameKey = StringNormalizer.normalize(displayName)
                if tokensByNormalizedName[nameKey] == nil {
                    tokensByNormalizedName[nameKey] = IndexedToken(token: cask.token, provenance: .displayName)
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
            return .managed(token: installedToken, provenance: .installedToken)
        }

        let matched: IndexedToken? = customMappings[applicationName]
            .map { IndexedToken(token: $0, provenance: .curatedMapping) }
            ?? index.tokensByNormalizedName[normalizedName]

        guard let matched else {
            return .none
        }

        if index.installedCasks.contains(matched.token) {
            return .managed(token: matched.token, provenance: matched.provenance)
        }

        if let installedToken = index.normalizedInstalledCasks[StringNormalizer.normalize(matched.token)] {
            return .managed(token: installedToken, provenance: matched.provenance)
        }

        return .candidate(token: matched.token, provenance: matched.provenance)
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
