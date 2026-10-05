import Foundation

/// What accepting a reported publisher change would do, decided against the bundle on disk.
///
/// A vendor can legitimately move to a new Developer ID — Proton Mail went from Proton
/// Technologies AG (6UN54H93QT) to Proton AG (2SB5Z68H26). The watchdog cannot tell that apart
/// from a takeover, so only the user can accept it. That consent covers the Team ID they were
/// shown and nothing else: the decision is taken against a fresh read of the installed bundle.
public enum PublisherChangeAcceptance: Equatable, Sendable {
    /// Re-baseline to `new`; `previous` is the trusted ID the user is replacing.
    case accept(previous: String?, new: String)
    /// The installed bundle already matches every recorded baseline (e.g. after a rollback
    /// restored the trusted build), so there is no change to accept.
    case alreadyTrusted
    /// The installed bundle has no readable Team ID; nothing measurable to trust.
    case signatureUnreadable
    /// The bundle was re-signed by a publisher other than the one the user was shown.
    case installedDiffersFromReport(reported: String, installed: String)

    /// - Parameters:
    ///   - reportedTeamID: the new Team ID the warning showed, if it named one.
    ///   - installedTeamID: the Team ID read from the installed bundle right now.
    ///   - trustedTeamIDs: the baselines recorded under every key this app is tracked by.
    public static func decide(
        reportedTeamID: String?,
        installedTeamID: String?,
        trustedTeamIDs: [String?]
    ) -> PublisherChangeAcceptance {
        guard let installedTeamID, !installedTeamID.isEmpty else { return .signatureUnreadable }
        let recorded = trustedTeamIDs.compactMap { $0 }.filter { !$0.isEmpty }
        if !recorded.isEmpty, recorded.allSatisfy({ $0 == installedTeamID }) { return .alreadyTrusted }
        if let reportedTeamID, !reportedTeamID.isEmpty, reportedTeamID != installedTeamID {
            return .installedDiffersFromReport(reported: reportedTeamID, installed: installedTeamID)
        }
        return .accept(previous: recorded.first { $0 != installedTeamID }, new: installedTeamID)
    }
}
