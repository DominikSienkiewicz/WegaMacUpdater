import Foundation

/// Advisory triage of release notes (**FEAT-06 / Prop#3**): flag a likely *security*
/// fix so power users can prioritize. **Advisory only** — it never gates or
/// auto-applies an update (the classification can be wrong).
///
/// One tier: a deterministic keyword scan, always available and synchronous. Its
/// callers are SwiftUI view bodies and the "security only" list filter, both of
/// which need an answer in the same turn they render.
///
/// `LT-04` removed a second, never-called tier built on Apple's Foundation Models
/// guided-generation macros. It had no call site, its natural-language summary was
/// never displayed, and the only thing it reliably produced was a build-time
/// dependency on the `FoundationModelsMacros` plugin — which ships with the full
/// Xcode only. Reintroducing an on-device model tier is a product decision, not a
/// refactor: such a tier is asynchronous and Apple-Intelligence gated, so every
/// call site above has to grow cached state first.
/// `ReleaseNotesTriageTests` guards the layer against drifting back.
public struct ReleaseTriageResult: Equatable, Sendable {
    public var isLikelySecurityFix: Bool
    public var matchedSignals: [String]

    public init(isLikelySecurityFix: Bool, matchedSignals: [String]) {
        self.isLikelySecurityFix = isLikelySecurityFix
        self.matchedSignals = matchedSignals
    }
}

public enum ReleaseNotesTriage {
    /// Substrings that strongly indicate a security-relevant change (lowercased).
    static let securitySignals: [String] = [
        "cve-", "cwe-", "security", "vulnerab", "exploit", "rce", "remote code",
        "privilege escalation", "sandbox escape", "0-day", "zero-day",
        "malicious", "spoof", "xss", "csrf", "injection", "use-after-free", "overflow",
    ]

    /// Pure heuristic triage — no network, no model. Always available.
    public static func heuristic(_ notes: String) -> ReleaseTriageResult {
        let lower = notes.lowercased()
        let hits = securitySignals.filter { lower.contains($0) }
        return ReleaseTriageResult(isLikelySecurityFix: !hits.isEmpty, matchedSignals: hits)
    }
}
