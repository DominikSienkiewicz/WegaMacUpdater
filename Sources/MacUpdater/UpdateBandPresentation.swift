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
    let sources: [SourceChip]
    let wegaLine: String

    /// Today's results-heading rule: only a stale snapshot names its date ("Znaleziono"); the
    /// rest say "Sprawdzono" and a time. `freshnessIsExplicit` still colours anything older
    /// than fresh.
    var freshnessText: String? {
        guard let lastCheck else { return nil }
        return freshness == .stale
            ? trf("Znaleziono %@", lastCheck.formatted(date: .abbreviated, time: .shortened))
            : trf("Sprawdzono %@", lastCheck.formatted(date: .omitted, time: .shortened))
    }

    var freshnessIsExplicit: Bool { freshness.needsExplicitTimestamp }

    /// The eyebrow's source chips, in scan order.
    var sourceChips: [SourceChip] { sources }

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

    /// One source in the eyebrow: its stamp token, and whether it answered the scan.
    struct SourceChip: Equatable {
        let token: String
        let isVerified: Bool

        /// The sources that took part in the scan, each verified only when it succeeded. A
        /// source that failed still took part (see `ScanSource.active(in:)`), so it keeps its
        /// token unverified. With no per-source detail every source Wega checks is named, and
        /// none is verified.
        static func chips(from reports: ScanSourceReports) -> [SourceChip] {
            let active = ScanSource.active(in: reports)
            guard !active.isEmpty else {
                return ScanSource.allCases.map { SourceChip(token: SourceCommunication.stampToken($0), isVerified: false) }
            }
            return active.map { source in
                SourceChip(
                    token: SourceCommunication.stampToken(source),
                    isVerified: report(for: source, in: reports)?.outcome == .succeeded
                )
            }
        }

        private static func report(for source: ScanSource, in reports: ScanSourceReports) -> ScanSourceReport? {
            switch source {
            case .homebrew: reports.brew
            case .appStore: reports.mas
            case .npm:      reports.npm
            case .manual:   reports.manual
            }
        }
    }
}
