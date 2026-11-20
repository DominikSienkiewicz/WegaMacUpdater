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
    /// Set when a source stayed quiet, so the headline never reads as the whole story.
    var incompleteNote: String? = nil
    /// Queued manual apps: the band hands them to their developer instead of installing them.
    var handOffCount: Int = 0

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

    /// The count, then the incomplete-check note, then the security nuance. The note comes
    /// before the nuance because the headline truncates at its tail, and losing "the check was
    /// incomplete" turns a partial answer into a complete-looking one.
    var headline: String {
        var parts = [trp("%@ aktualizacji", totalCount)]
        if let incompleteNote { parts.append(incompleteNote) }
        if urgentCount > 0 { parts.append(trp("%@ z możliwą poprawką bezp.", urgentCount)) }
        return parts.joined(separator: " · ")
    }

    var line: String { wegaLine }

    /// The queue, and when manual apps are in it, how many of them the developer finishes.
    var queueSummary: String {
        handOffCount == 0
            ? trf("%@ w kolejce", "\(queueCount)")
            : trf("%@ w kolejce · %@ dokończysz u producenta", "\(queueCount)", "\(handOffCount)")
    }

    var showsPlanLink: Bool { queueCount > 0 }

    var buttonTitle: String { queueCount == 0 ? tr("Nic nie zaznaczono") : tr("Aktualizuj") }

    var buttonCount: Int? { queueCount == 0 ? nil : queueCount }

    /// An empty button reads as it is drawn; a button with a queue says what it will update.
    var buttonAccessibilityLabel: String {
        queueCount == 0 ? buttonTitle : trf("Zaktualizuj wybrane (%@)", "\(queueCount)")
    }

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

/// UX-14 — what the selection says: its text, and how much of the queue the rollback net
/// covers (the band reads `protectionText`).
struct UpdateActionBarSummary: Equatable {
    let selectedCount: Int
    let visibleCount: Int
    let protectedCount: Int
    let queuedCount: Int
    /// Casks in the queue whose rollback verdict has not arrived yet.
    let unverifiedCount: Int

    init(
        selectedCount: Int,
        visibleCount: Int,
        targets: [OutdatedItem],
        protection: [String: RollbackProtection.Verdict]
    ) {
        let casks = targets.filter { $0.kind == .cask }
        self.selectedCount = selectedCount
        self.visibleCount = visibleCount
        self.queuedCount = targets.count
        self.protectedCount = casks.filter { protection[$0.name] == .protected }.count
        self.unverifiedCount = casks.filter { protection[$0.name] == nil }.count
    }

    /// An empty selection says what is missing instead of offering a dead button silently.
    var selectionText: String {
        selectedCount == 0
            ? tr("Zaznacz, co mam zaktualizować")
            : trf("%@ z %@ zaznaczonych", "\(selectedCount)", "\(visibleCount)")
    }

    /// Undo coverage against the whole queue, formulae included. A cask without a verdict is
    /// never counted as protected: the band says it is still checking.
    var protectionText: String? {
        guard queuedCount > 0 else { return nil }
        if unverifiedCount > 0 { return tr("Sprawdzam możliwość cofnięcia") }
        return trf("Cofnięcie: %@ z %@", "\(protectedCount)", "\(queuedCount)")
    }
}
