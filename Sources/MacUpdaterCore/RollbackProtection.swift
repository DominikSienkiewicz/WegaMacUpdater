import Foundation

/// Whether Wega's snapshot → canary → auto-rollback chain can cover a given cask (M5).
///
/// The snapshot is a copy-on-write clone of an `.app` bundle. A cask that installs no app
/// — a bare `pkg`, an `installer`, a CLI-only `binary` — cannot be cloned and therefore
/// cannot be restored when a Gatekeeper canary fails. That hole cannot be closed, only
/// disclosed: the UI shows a shield where the net exists and says "no protection" where it
/// does not, and the log carries a warning either way.
public enum RollbackProtection {
    public enum Reason: Equatable, Sendable {
        /// Nothing to clone: the cask installs no `.app` bundle.
        case noAppBundle
    }

    public enum Verdict: Equatable, Sendable {
        case protected
        case unprotected(Reason)

        /// Unprotected upgrades are worth a line in the log — an upgrade with no way back
        /// is exactly the event a user will want to find afterwards.
        public var deservesWarning: Bool {
            if case .unprotected = self { return true }
            return false
        }
    }

    public static func evaluate(profile: CaskArtifactProfile) -> Verdict {
        profile.contains(.app) ? .protected : .unprotected(.noAppBundle)
    }
}
