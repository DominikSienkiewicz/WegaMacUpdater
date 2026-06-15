import Foundation

/// Advisory triage of release notes (**FEAT-06 / Prop#3**): summarize and flag a
/// likely *security* fix so power users can prioritize. **Advisory only** — it
/// never gates or auto-applies an update (the classification can be wrong).
///
/// Two tiers, by capability:
/// - **Heuristic** (always, macOS 14+): keyword/regex scan. Cheap, deterministic.
/// - **On-device LLM** (macOS 26+, Apple Intelligence): Apple's Foundation Models
///   with guided generation — behind `#if canImport(FoundationModels)` so the app
///   still builds on older SDKs, and `@available` so it only runs where supported.
public struct ReleaseTriageResult: Equatable, Sendable {
    public var isLikelySecurityFix: Bool
    public var matchedSignals: [String]
    /// Natural-language summary — only populated by the on-device model tier.
    public var summary: String?

    public init(isLikelySecurityFix: Bool, matchedSignals: [String], summary: String? = nil) {
        self.isLikelySecurityFix = isLikelySecurityFix
        self.matchedSignals = matchedSignals
        self.summary = summary
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

#if canImport(FoundationModels)
import FoundationModels

// NOTE: API surface per WWDC25 (Foundation Models framework). If the shipping SDK
// renames anything, adjust here only — the heuristic tier above is unaffected.
@available(macOS 26, *)
public extension ReleaseNotesTriage {
    @Generable
    struct Triage {
        @Guide(description: "true only if the notes describe a security fix or vulnerability patch")
        public var isSecurityFix: Bool
        @Guide(description: "one neutral sentence summarizing what changed")
        public var summary: String
    }

    /// On-device, privacy-preserving triage with guided (typed) output. Falls back
    /// to the heuristic on any model error so a result is always returned.
    static func onDevice(_ notes: String) async -> ReleaseTriageResult {
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: notes, generating: Triage.self)
            let triage = response.content
            return ReleaseTriageResult(
                isLikelySecurityFix: triage.isSecurityFix,
                matchedSignals: heuristic(notes).matchedSignals,
                summary: triage.summary
            )
        } catch {
            return heuristic(notes)
        }
    }
}
#endif
