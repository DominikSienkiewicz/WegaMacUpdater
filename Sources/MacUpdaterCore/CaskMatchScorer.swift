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
    ///    (Cask-side Team ID isn't in `brew info` today; this is wired for a future
    ///    publisher ledger / FEAT-04 watchdog. Until then it's typically nil.)
    /// 2. **Curated mapping** — an explicit entry in `customCaskMappings` is trusted.
    /// 3. **Exact normalized token** match.
    /// 4. **Exact normalized display-name** match.
    /// Otherwise low.
    public static func score(
        applicationName: String,
        caskToken: String,
        caskNames: [String],
        viaCustomMapping: Bool,
        installedAppTeamID: String? = nil,
        caskExpectedTeamID: String? = nil
    ) -> CaskMatchConfidence {
        if let installed = installedAppTeamID, let expected = caskExpectedTeamID, !expected.isEmpty {
            return installed == expected ? .high : .low
        }
        if viaCustomMapping { return .high }

        let normalizedApp = StringNormalizer.normalize(applicationName)
        if StringNormalizer.normalize(caskToken) == normalizedApp { return .high }
        if caskNames.contains(where: { StringNormalizer.normalize($0) == normalizedApp }) { return .medium }
        return .low
    }
}
