import Foundation

/// Outcome of a single manual-update checker for one app. Distinguishes the three
/// cases that used to collapse into `nil`:
///
/// - `.notApplicable` — this checker doesn't handle this app (wrong bundle id, no
///   version to compare). No network was attempted.
/// - `.upToDate` — the check completed and the app is current.
/// - `.outdated` — a newer version is available.
/// - `.unavailable` — the source was temporarily silent (transport error or 5xx
///   server error). We genuinely *don't know*, but it's an upstream/transient
///   outage, not a problem with our request. Logged at WARNING and NOT counted
///   toward the "list may be incomplete" banner (unlike `.failed`).
/// - `.failed` — a genuine error: an HTTP 4xx, or a 200 response we couldn't
///   parse. We genuinely *don't know*. This is the case the UI must not render
///   as "up to date".
public enum ManualCheckResult: Sendable, Equatable {
    case notApplicable
    case upToDate
    case outdated(ManualOutdatedApp)
    /// The source was temporarily silent — a transport error or a 5xx server
    /// error. We genuinely don't know, but it's an upstream/transient outage, not
    /// a problem with our request. Logged at WARNING and NOT counted toward the
    /// "list may be incomplete" banner (unlike `.failed`).
    case unavailable
    case failed
}
