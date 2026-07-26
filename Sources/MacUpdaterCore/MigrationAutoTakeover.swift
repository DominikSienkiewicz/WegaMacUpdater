/// REL-08 — decides whether a `.app`→cask match is trustworthy enough to run
/// `brew install --cask --force <token>`, which overwrites the app in place.
///
/// This is the production consumer `CaskMatchConfidence.allowsAutoConfirm` never had: the
/// score used to be computed only to colour a badge, so a low-confidence match could still
/// overwrite the user's app with a different program. The decision is pure so it can be
/// tested without a running migration; `MigrationStore` calls it before executing.
public enum MigrationAutoTakeover {
    public enum Decision: Equatable, Sendable {
        /// Confidence is high enough to take over without an extra confirmation.
        case allowed
        /// Plausible but not certain — a human must confirm the token before the force install.
        case requiresConfirmation
        /// Too weak to risk overwriting the app — the takeover must not proceed.
        case blocked
    }

    public static func decide(_ confidence: CaskMatchConfidence) -> Decision {
        if confidence.allowsAutoConfirm { return .allowed }
        return confidence == .low ? .blocked : .requiresConfirmation
    }
}
