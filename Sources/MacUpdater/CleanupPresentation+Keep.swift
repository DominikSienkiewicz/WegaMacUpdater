import Foundation
import MacUpdaterCore

// MARK: - Keep choice

extension CleanupPresentation {
    /// The state of a duplicated tool's "zostaw" radio on one of its candidate copies.
    enum KeepControl: Equatable {
        case kept, notKept, undecided
    }

    /// The radio's visible label.
    static var keepTitle: String { tr("zostaw") }

    static func keepAccessibilityLabel(for row: Row) -> String {
        trf("Zostaw %@", row.title)
    }

    /// The radio a candidate copy shows; nil for a finding that offers no choice.
    static func keepControl(of finding: CleanupFinding) -> KeepControl? {
        switch finding.candidate?.keep {
        case .kept?: .kept
        case .notKept?: .notKept
        case .undecided?: .undecided
        case nil: nil
        }
    }

    /// The note that replaces a button on a copy that stays or waits for the choice; nil when the
    /// copy's own action decides the row.
    static func keepNote(for finding: CleanupFinding) -> String? {
        switch finding.candidate?.keep {
        case .kept?: tr("zostaje")
        case .undecided?: tr("wybierz kopię, którą zostawić")
        case .notKept?, nil: nil
        }
    }

    /// A broken link on `PATH` carries a copyable `unlink` command, which the row shows.
    static func isBrokenLinkOnPath(_ finding: CleanupFinding) -> Bool {
        finding.detector == .pathDuplicates && finding.status == .brokenLink
    }

    /// For the copy `PATH` uses now, when another copy is kept: which copy Terminal falls back to.
    static func takeoverText(for finding: CleanupFinding, home: URL) -> String? {
        guard case .notKept? = finding.candidate?.keep, let path = finding.candidate?.takesOver else { return nil }
        return trf(
            "Tej kopii używa teraz Terminal. Po usunięciu użyje %@.", CleanupReportRenderer.tildePath(path, home: home)
        )
    }

    /// The keep state of every D1 copy that offers the choice, by finding id.
    static func linkKeeps(in report: CleanupReport) -> [String: CleanupKeep] {
        var keeps: [String: CleanupKeep] = [:]
        for finding in report.findings where finding.detector == .pathDuplicates {
            if let keep = finding.candidate?.keep { keeps[finding.id] = keep }
        }
        return keeps
    }

    /// A Files and Folders entry linked to a copy the user decided about follows that decision;
    /// while the copy waits for the choice (or offers none) the stored link kind's text stays.
    static func linkedEntryText(_ reason: CleanupReason, linkKeeps: [String: CleanupKeep]) -> String? {
        guard case .tccEntry(let grants, let link?) = reason else { return nil }
        let label: String
        switch linkKeeps[link.findingID] {
        case .kept?: label = tr("dotyczy kopii, którą zostawiasz")
        case .notKept?: label = tr("dotyczy kopii do usunięcia")
        case .undecided?, nil: return nil
        }
        return tccEntryText(grants: grants, link: link, label: label)
    }
}
