import Foundation
import WegaHelperKit

/// LT-03 — the publisher corroboration that `CaskMatchScorer`'s strongest branch expects.
///
/// The scorer has always accepted `installedAppTeamID` / `caskExpectedTeamID`, but no
/// production call site ever supplied them, so its best signal was dead code: a `.app`
/// signed by one publisher could still be adopted by a cask known to ship another, and the
/// decision rested entirely on how similar two strings looked. `TeamIDLedger` has been
/// recording the missing half all along (the publisher seen for `cask:<token>`), so this
/// type is the supply the branch was waiting for.
public struct CaskPublisherCorrelation: Equatable, Sendable {
    /// Nothing measurable to correlate — the scorer falls back to the name/token heuristics
    /// and behaves exactly as it did before LT-03.
    public static let unknown = CaskPublisherCorrelation(
        installedAppTeamID: nil,
        caskExpectedTeamID: nil
    )

    /// Developer ID that signs the installed bundle, as read from its code signature.
    public let installedAppTeamID: String?
    /// Developer ID the ledger last recorded for the cask this app would be adopted by.
    public let caskExpectedTeamID: String?

    public init(installedAppTeamID: String?, caskExpectedTeamID: String?) {
        self.installedAppTeamID = installedAppTeamID
        self.caskExpectedTeamID = caskExpectedTeamID
    }

    /// Both publishers are known and they disagree. `brew install --cask --force <token>`
    /// overwrites the app in place, so this is the one signal that must stop a takeover no
    /// matter how convincing the names are.
    public var isPublisherMismatch: Bool {
        guard let installedAppTeamID, let caskExpectedTeamID, !caskExpectedTeamID.isEmpty else {
            return false
        }
        return installedAppTeamID != caskExpectedTeamID
    }
}

/// Builds `CaskPublisherCorrelation` values for migration candidates.
///
/// The order in which the two sources are consulted is the performance contract, and it is
/// the ARCH-05b lesson applied to a second signal: the ledger lookup is an in-memory
/// dictionary read, while reading a bundle's code signature is filesystem plus
/// Security-framework work. The ledger is therefore consulted **first**, and a signature is
/// read **only** for a candidate whose cask has a recorded publisher — for every other
/// candidate the scorer would ignore the value anyway, so the correlation costs nothing and
/// activating it cannot turn a scan back into per-application I/O.
///
/// Both sources are injected so the decision is testable without a signed bundle on disk or
/// a populated `UserDefaults`; `live` is the production wiring.
public struct CaskPublisherCorrelator: Sendable {
    private let expectedTeamIDForCask: @Sendable (String) -> String?
    private let installedTeamIDForApp: @Sendable (URL) -> String?

    public init(
        expectedTeamIDForCask: @escaping @Sendable (String) -> String?,
        installedTeamIDForApp: @escaping @Sendable (URL) -> String?
    ) {
        self.expectedTeamIDForCask = expectedTeamIDForCask
        self.installedTeamIDForApp = installedTeamIDForApp
    }

    /// Correlation for one candidate. Reads the installed signature only when there is a
    /// recorded cask publisher to compare it against.
    public func correlate(caskToken: String, appPath: URL) -> CaskPublisherCorrelation {
        guard let expected = expectedTeamIDForCask(caskToken), !expected.isEmpty else {
            return .unknown
        }
        return CaskPublisherCorrelation(
            installedAppTeamID: installedTeamIDForApp(appPath),
            caskExpectedTeamID: expected
        )
    }

    /// One pass over a scan's candidates, keyed by `ApplicationInfo.id`. Candidates without
    /// a cask token, and those whose cask has no recorded publisher, are simply absent — a
    /// missing entry reads as `.unknown`, which scores exactly as it did before.
    public func correlations(
        for applications: some Sequence<ApplicationInfo>
    ) -> [String: CaskPublisherCorrelation] {
        applications.reduce(into: [String: CaskPublisherCorrelation]()) { partial, app in
            guard let token = app.caskToken else { return }
            let correlation = correlate(caskToken: token, appPath: app.path)
            guard correlation != .unknown else { return }
            partial[app.id] = correlation
        }
    }

    /// Production wiring: the publisher history the cask watchdog already keeps
    /// (`CaskRollbackGuard` records it into `TeamIDLedger` under the `cask:<token>` key)
    /// against the installed bundle's Developer ID.
    public static let live = CaskPublisherCorrelator(
        expectedTeamIDForCask: { TeamIDLedger.shared.teamID(forBundleID: "cask:\($0)") },
        installedTeamIDForApp: { CodeSignatureVerifier.teamID(ofAppAt: $0) }
    )
}
