import Foundation
import MacUpdaterCore

// MARK: - C2 stage 4 — the after-update summary's doors
//
// `report(run:planned:…)` opens the report; everything else that touches it goes through here.
// Closing has one door so a changed publisher the user has not settled cannot be lost: the
// summary carries it while it is open, and the door raises today's sticky banner for it.
extension ScanStore {
    /// Closes the summary — "Zamknij podsumowanie", "Pozostałe aktualizacje ›", any scan the user
    /// or the launch starts, and the next run — and raises the sticky "Zmienił się podpis
    /// producenta" banner for every publisher change still unsettled, in plan order.
    ///
    /// Each is the banner `report(run:)` raised before the summary existed: the same title, the
    /// same words and the trust action for a cask, which names the bundle the run prepared
    /// (`trustPublisherAction(for:)`). It is built inline, so the sticky banners'
    /// guard (`BannerDismissalTests`) sees that it is raised as a `.danger`.
    func closeRunReport() {
        guard let report = runReport else { return }
        setRunReport(nil)
        for entry in report.unsettledPublisherChanges {
            guard let message = entry.publisherSentence else { continue }
            showStickyBanner(BannerData(variant: .danger, title: tr("Zmienił się podpis producenta"),
                                        message: message, action: trustPublisherAction(for: entry)))
        }
    }

    /// An undo restored `token` (after the journal mark and the pin).
    func markRunReportUndone(token: String, restoredVersion: String?) {
        guard var report = runReport else { return }
        report.markUndone(token: token, restoredVersion: restoredVersion)
        setRunReport(report)
    }

    /// The ledger now trusts the publisher `token` is signed by, or already did.
    func settleRunReportPublisher(token: String) {
        guard var report = runReport else { return }
        report.settlePublisher(token: token)
        setRunReport(report)
    }
}
