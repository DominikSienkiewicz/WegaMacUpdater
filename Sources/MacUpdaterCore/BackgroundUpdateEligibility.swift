import Foundation

/// Whether a cask may be upgraded without the user watching (F3).
///
/// Background updating is only responsible where the outcome is verifiable and reversible.
/// Two properties decide it, both readable from `brew info --json`:
///
/// 1. **An app and no privileged artifacts.** `pkg`, `installer` and `preflight` can run
///    arbitrary code or demand an admin password. A cask must install an `.app` and declare
///    only `app` / `binary` / `zap` artifacts to qualify — without an app there is nothing
///    the rollback guard can clone and verify.
/// 2. **A concrete `sha256`.** Without it Homebrew verifies nothing (`:no_check`), and an
///    unattended install of an unverified download is precisely the risk we refuse.
///
/// Liveness checks (is the app running?) and snapshot feasibility are runtime concerns and
/// deliberately live outside this predicate, which stays pure and exhaustively testable.
public enum BackgroundUpdateEligibility {
    /// Artifacts a cask may declare and still be upgraded unattended.
    static let safeArtifactKinds: Set<CaskArtifactKind> = [.app, .binary, .zap]

    public enum Rejection: Equatable, Sendable {
        /// The cask declares no artifacts at all — nothing is known about what it installs.
        case noArtifacts
        /// The cask installs no `.app`, so the rollback guard has nothing to protect.
        case noAppBundle
        /// A `pkg` / `installer` / `preflight` stanza, or a stanza we do not recognise.
        case privilegedArtifact
        /// Homebrew would install without verifying the download (`:no_check`, or absent).
        case noChecksum
    }

    public enum Verdict: Equatable, Sendable {
        case eligible
        case ineligible(Rejection)
    }

    /// `download` is optional because `brew info` may not report one; a cask whose download
    /// we cannot inspect is treated exactly like a cask with no checksum.
    public static func evaluate(profile: CaskArtifactProfile, download: CaskDownloadInfo?) -> Verdict {
        let kinds = profile.artifactKinds
        guard !kinds.isEmpty else { return .ineligible(.noArtifacts) }
        guard kinds.isSubset(of: safeArtifactKinds) else { return .ineligible(.privilegedArtifact) }
        guard kinds.contains(.app) else { return .ineligible(.noAppBundle) }
        guard download?.hasChecksum == true else { return .ineligible(.noChecksum) }
        return .eligible
    }
}
