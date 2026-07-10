import Foundation

/// Chooses which casks may be upgraded unattended (F3).
///
/// This is the gate in front of the only thing Wega does to a user's machine without them
/// watching. Every condition below is necessary, and the default answer is no:
///
/// - **the user opted this app in** — silence is not consent;
/// - **`BackgroundUpdateEligibility` says yes** — no `pkg` / `installer` / `preflight`
///   hooks (they run arbitrary code and can demand an admin password), and a concrete
///   `sha256` so Homebrew actually verifies the download;
/// - **the app is not running** — replacing a live app's bundle corrupts its session;
/// - **no ignore or pin rule stands in the way** — a background job never overrides an
///   explicit "hold here".
///
/// Sudo-requiring casks are excluded by construction rather than by policy: they carry the
/// privileged artifacts the eligibility predicate refuses. That is a load-bearing rule, not
/// a UX preference.
public enum BackgroundUpdatePlanner {
    /// Everything the decision depends on, gathered once. Passing six loose arguments made
    /// it too easy to hand them over in the wrong order — and each of them is a veto.
    public struct Inputs {
        public var candidates: [String]
        public var profiles: [String: CaskArtifactProfile]
        public var downloads: [String: CaskDownloadInfo]
        public var optedIn: Set<String>
        public var runningProcessTokens: Set<String>
        public var policies: [String: UpdatePolicy]

        public init(
            candidates: [String],
            profiles: [String: CaskArtifactProfile],
            downloads: [String: CaskDownloadInfo],
            optedIn: Set<String>,
            runningProcessTokens: Set<String>,
            policies: [String: UpdatePolicy]
        ) {
            self.candidates = candidates
            self.profiles = profiles
            self.downloads = downloads
            self.optedIn = optedIn
            self.runningProcessTokens = runningProcessTokens
            self.policies = policies
        }
    }

    /// Candidate order is preserved so the completion notification can name apps predictably.
    public static func eligibleTokens(_ inputs: Inputs) -> [String] {
        inputs.candidates.filter { token in
            guard inputs.optedIn.contains(token) else { return false }
            guard !inputs.runningProcessTokens.contains(token) else { return false }
            // Casks are keyed `c:<token>` in the policy map — see `OutdatedItem.policyKey`.
            guard inputs.policies["c:\(token)"] == nil else { return false }
            // A cask we could not inspect is a cask we do not touch.
            guard let profile = inputs.profiles[token] else { return false }
            return BackgroundUpdateEligibility.evaluate(
                profile: profile,
                download: inputs.downloads[token]
            ) == .eligible
        }
    }
}
