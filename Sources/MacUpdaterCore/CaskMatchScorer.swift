import Foundation

/// Confidence that a manually-installed `.app` truly maps to a given Homebrew
/// cask (**FEAT-02 / Prop#4**). Additive on top of `CaskMatcher` (which only
/// answers managed/candidate/none) so existing matching behaviour is untouched.
///
/// Why it matters: migration runs `brew install --cask --force <token>` — a wrong
/// match overwrites the user's app with a *different* program. This scorer drives
/// the UI decision "auto-confirm vs require explicit confirmation".
public enum CaskMatchConfidence: Int, Equatable, Sendable, Comparable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// High confidence is the only level safe to migrate without an extra confirm.
    public var allowsAutoConfirm: Bool { self == .high }
}

public enum CaskMatchScorer {
    /// Scores the match from the strongest available signal.
    ///
    /// Priority of signals (strongest first):
    /// 1. **Team ID corroboration** — when both the installed app's Team ID and the
    ///    cask's expected publisher Team ID are known, equality ⇒ high, mismatch ⇒ low.
    ///    LT-03 supplies both from `CaskPublisherCorrelation`; a mismatch is a hard veto.
    /// 2. **How the match was found** — ``CaskMatchProvenance``, decided by `CaskMatcher`.
    ///    A bundle-identifier, curated-entry or token hit is certain; a display-name hit
    ///    is plausible.
    ///
    /// LT-03 (follow-up) — signals 2 and 3 used to be re-derived here from an application
    /// name, a token and a list of cask names, which meant a caller had to reconstruct a
    /// conclusion `CaskMatcher` had already reached. Neither call site could, so both passed
    /// `viaCustomMapping: false` and `caskNames: []` and the signals were dead — and because
    /// `MigrationAutoTakeover` turns `.low` into `.blocked`, the whole curated table was
    /// refused. Taking the provenance instead makes that unrepresentable: there is no longer
    /// a parameter a caller can silently get wrong.
    public static func score(
        provenance: CaskMatchProvenance,
        installedAppTeamID: String? = nil,
        caskExpectedTeamID: String? = nil
    ) -> CaskMatchConfidence {
        if let installed = installedAppTeamID, let expected = caskExpectedTeamID, !expected.isEmpty {
            return installed == expected ? .high : .low
        }

        switch provenance {
        case .bundleIdentifier, .installedToken, .curatedMapping, .token: return .high
        case .displayName:                                                return .medium
        }
    }

    /// The score for an app the matcher never tied to a cask. Kept explicit so "nothing is
    /// known" cannot be spelled as a provenance and quietly read as a weak match.
    public static let unmatched: CaskMatchConfidence = .low
}
