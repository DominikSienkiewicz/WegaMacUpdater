import Foundation
import MacUpdaterCore

/// UXP-13 — what a running scan is doing, in Wega's words. One function for the band's
/// headline and the first scan's caption, so the two screens never name different steps.
enum ScanPhaseCopy {
    /// The step the scan is on. `brew update` comes first and is slow, so it gets its own
    /// caption; a scan that has not named a phase yet is about to ask Homebrew.
    static func caption(progress: ScanProgress?, catalogRefreshing: Bool) -> String {
        if catalogRefreshing { return tr("Odświeżam katalog Homebrew…") }
        guard case .running(let phase) = progress else { return tr("Wega węszy po Homebrew…") }
        switch phase {
        case .brew:   return tr("Wega węszy po Homebrew…")
        case .mas:    return tr("Wega węszy w App Store…")
        case .npm:    return tr("Wega węszy w npm…")
        case .manual: return tr("Wega węszy u producentów…")
        }
    }
}

/// UXP-13 — what the band says while a scan runs in place, decided away from the views: the
/// time the patrol has taken, the phase, the vendor count and what was found so far. It counts
/// what has happened and never estimates what is left.
struct UpdateBandScanPresentation: Equatable {
    let progress: ScanProgress?
    let catalogRefreshing: Bool
    let startedAt: Date?
    let manual: ManualScanProgress?
    /// The updates on the list right now; the scan replaces them source by source.
    let foundSoFar: Int

    /// "Trwa obchód · 0:07" — counted from the scan's start, not towards an end.
    func eyebrow(now: Date) -> String {
        trf("Trwa obchód · %@", Self.elapsed(from: startedAt ?? now, to: now))
    }

    var headline: String { ScanPhaseCopy.caption(progress: progress, catalogRefreshing: catalogRefreshing) }

    /// The vendor count once the vendor phase reports one; until then, or when it has no app to
    /// ask, why the list is inert.
    var line: String {
        guard let manual, manual.totalApps > 0 else { return tr("Zaznaczanie wróci, gdy skan się skończy.") }
        return trf("Producenci: %@ %@", "\(manual.checkedApps)", trp("z %@ aplikacji", manual.totalApps))
    }

    var summary: String { trp("%@ aktualizacji", foundSoFar) + " " + tr("do tej pory") }

    /// The strip's own phase rule, so the chips and the ring cannot claim a source the scan
    /// has not reached.
    var steps: [ScanPhaseStrip.Step] { ScanPhaseStrip.steps(for: progress) }

    var completedSources: Int { steps.filter { $0.state == .done }.count }

    var totalSources: Int { steps.count }

    var ringAccessibilityValue: String { Self.sourcesValue(completed: completedSources, total: totalSources) }

    /// What VoiceOver hears for the ring: "2 z 4 źródeł".
    static func sourcesValue(completed: Int, total: Int) -> String {
        trf("%@ z %@ źródeł", "\(completed)", "\(total)")
    }

    /// Minutes and seconds, "0:07" or "12:05". A clock that ran backwards reads as zero.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
