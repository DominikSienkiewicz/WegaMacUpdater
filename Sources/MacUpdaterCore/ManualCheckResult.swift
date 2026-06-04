import Foundation

/// Outcome of a single manual-update checker for one app. Distinguishes the three
/// cases that used to collapse into `nil`:
///
/// - `.notApplicable` — this checker doesn't handle this app (wrong bundle id, no
///   version to compare). No network was attempted.
/// - `.upToDate` — the check completed and the app is current.
/// - `.outdated` — a newer version is available.
/// - `.failed` — the network request or response parsing failed, so we genuinely
///   *don't know*. This is the case the UI must not render as "up to date".
public enum ManualCheckResult: Sendable, Equatable {
    case notApplicable
    case upToDate
    case outdated(ManualOutdatedApp)
    case failed
}
