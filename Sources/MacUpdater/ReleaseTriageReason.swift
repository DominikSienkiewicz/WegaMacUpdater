import MacUpdaterCore

/// Why Wega flagged a release as a possible security fix: the words that matched.
enum ReleaseTriageReason {
    static func text(signals: [String]) -> String? {
        guard !signals.isEmpty else { return nil }
        let quoted = signals.map { "„\($0)”" }.joined(separator: ", ")
        return trf("Wega znalazła w notatkach: %@", quoted)
    }
}
