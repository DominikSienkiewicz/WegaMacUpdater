import Foundation

/// UX-06 — the update sources Wega scans, as one small vocabulary the UI can generate its
/// copy from. The readiness screen and the results stamp used to hardcode "Homebrew / Mac
/// App Store" and "brew + mas", silently omitting npm and the manual checkers even though a
/// scan covers them. Naming the sources here — in scan order — lets both surfaces be built
/// from the sources that are actually active instead of a frozen string.
public enum ScanSource: CaseIterable, Sendable, Equatable {
    case homebrew
    case appStore
    case npm
    case manual
}

extension ScanSource {
    /// The sources that actually took part in the scan behind a result, in scan order.
    ///
    /// A source that is *not installed* is "not applicable" (F4) and never active. A source
    /// that was present but went silent stays active — the result still covers it, and it is
    /// the banner's job, not the stamp's, to say it failed. A `nil` report means the scan
    /// never reached that source (cancelled, or a detail-less restored result); the caller
    /// falls back to naming the sources Wega checks when nothing is active.
    public static func active(in reports: ScanSourceReports) -> [ScanSource] {
        var active: [ScanSource] = []
        if isActive(reports.brew)   { active.append(.homebrew) }
        if isActive(reports.mas)    { active.append(.appStore) }
        if isActive(reports.npm)    { active.append(.npm) }
        if isActive(reports.manual) { active.append(.manual) }
        return active
    }

    private static func isActive(_ report: ScanSourceReport?) -> Bool {
        guard let report else { return false }
        if case .notInstalled = report.outcome { return false }
        return true
    }
}
