import Foundation
import MacUpdaterCore

/// What the Updates band says, decided away from the views: the eyebrow, headline, summary
/// and the round button's wording.
struct UpdateBandPresentation: Equatable {
    let totalCount: Int
    let urgentCount: Int
    let queueCount: Int
    let protectionText: String?
    let lastCheck: Date?
    let freshness: ScanFreshness
    let activeSources: [ScanSource]
    let wegaLine: String

    /// Today's results-heading rule: the stale snapshot names its date, the rest a time.
    var freshnessText: String? {
        guard let lastCheck else { return nil }
        return freshness.needsExplicitTimestamp
            ? trf("Znaleziono %@", lastCheck.formatted(date: .abbreviated, time: .shortened))
            : trf("Sprawdzono %@", lastCheck.formatted(date: .omitted, time: .shortened))
    }

    var freshnessIsExplicit: Bool { freshness.needsExplicitTimestamp }

    var sourceTokens: [String] { activeSources.map(SourceCommunication.stampToken) }

    var headline: String {
        let total = trp("%@ aktualizacji", totalCount)
        guard urgentCount > 0 else { return total }
        return total + " · " + trp("%@ pilnych", urgentCount)
    }

    var line: String { wegaLine }

    var queueSummary: String { trf("%@ w kolejce", "\(queueCount)") }

    var showsPlanLink: Bool { queueCount > 0 }

    var buttonTitle: String { queueCount == 0 ? tr("Kolejka pusta") : tr("Aktualizuj") }

    var buttonCount: Int? { queueCount == 0 ? nil : queueCount }

    var buttonAccessibilityLabel: String { trf("Zaktualizuj wybrane (%@)", "\(queueCount)") }
}
