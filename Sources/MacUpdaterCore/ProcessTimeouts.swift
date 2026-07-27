import Foundation

/// REL-12 — how long one external command may take, expressed as the two limits that fail
/// for different reasons.
///
/// A wall-clock `deadline` alone is a bad fit for this app: a multi-gigabyte cask download
/// legitimately runs for an hour, so any deadline generous enough for it is useless against
/// a `brew`/`mas` that hung after ten seconds. An `idle` limit catches exactly that case —
/// the process is alive, holding the upgrade mutex and the UI, and has stopped saying
/// anything. Every request carries both; `nil` (unbounded) is no longer the default.
public struct ProcessTimeoutPolicy: Equatable, Sendable {
    /// Total wall-clock budget for the command, from launch to exit.
    public let deadline: TimeInterval
    /// How long the command may produce no output at all before it is considered hung.
    public let idle: TimeInterval

    public init(deadline: TimeInterval, idle: TimeInterval) {
        self.deadline = deadline
        self.idle = idle
    }

    /// Short local commands that talk to nothing over the network (`pgrep`, `killall`,
    /// `open`, `brew --version`). Anything slower than this is already pathological.
    public static let quick = ProcessTimeoutPolicy(deadline: 30, idle: 20)

    /// Metadata queries that do hit the network but produce no user-visible progress
    /// (`brew update`, `brew outdated`, `brew info`, `mas list`, `npm outdated`). Generous
    /// enough for a slow mirror, short enough that a stuck query cannot outlast a coffee.
    public static let query = ProcessTimeoutPolicy(deadline: 600, idle: 180)

    /// Installs and upgrades streamed to the live log (`brew upgrade`, `npm install -g`,
    /// `mas upgrade`). These download gigabytes, so the deadline is hours — the inactivity
    /// limit is what actually protects the run, and every progress line rearms it.
    public static let download = ProcessTimeoutPolicy(deadline: 7200, idle: 900)

    /// What a `ProcessRequest` gets when its caller names no policy. Bounded on purpose:
    /// forgetting to pass a limit must not resurrect the unbounded wait REL-12 is about.
    public static let `default` = query
}
