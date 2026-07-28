import Foundation

/// OBS-02 — where a notification takes you when you click it.
///
/// Wega posts three kinds of notification — the agent's "updates available", the summary of an
/// unattended round, and the report of an interrupted update that recovery settled — and until
/// now clicking any of them did the system default: bring the app forward, to whatever screen
/// it happened to be showing. The card's last criterion is that a notification leads to *the
/// operation it is about*, because "Wega naprawiła przerwaną aktualizację" is only useful next
/// to the log line that says what it restored.
///
/// The destination is written into the notification's `userInfo` when it is posted and read
/// back when it is clicked, so this file is the whole contract between the two ends — and it
/// is pure, so both halves are testable without posting a real notification or clicking one.
public enum NotificationRouting {
    /// The `userInfo` key carrying the destination. Namespaced because `userInfo` is a shared
    /// dictionary the system also writes into.
    public static let destinationKey = "wega.notification.destination"

    /// What a posted notification carries so it can be routed later.
    public static func payload(for destination: SidebarSelection) -> [String: String] {
        [destinationKey: destination.rawValue]
    }

    /// The destination a clicked notification asks for, or `nil` when it carries none.
    ///
    /// `nil` is a real answer, not a failure: a notification posted by an older build is still
    /// sitting in Notification Center and will be delivered without a payload. The caller must
    /// then do what Wega always did — bring the window forward and change nothing — rather
    /// than guess a destination and move the user somewhere they did not ask to go.
    public static func destination(from userInfo: [AnyHashable: Any]) -> SidebarSelection? {
        guard let raw = userInfo[destinationKey] as? String else { return nil }
        return SidebarSelection(rawValue: raw)
    }

    /// Where the summary of an unattended round belongs.
    ///
    /// A clean round goes to the updates list — the thing that changed. A round with anything
    /// critical in it goes to the log instead, because a failed rollback or a changed publisher
    /// is a *reason*, and the reason is not on the list; it is in the log line underneath it.
    public static func destination(forBackgroundRound summary: UpdateRunSummary) -> SidebarSelection {
        summary.critical.isEmpty ? .updates(.all) : .logs
    }

    /// Where a recovery report belongs. Always the log: the notification says an interrupted
    /// update was settled, and what it did — restored, aborted, committed — exists only there.
    public static let recoveryDestination: SidebarSelection = .logs

    /// Where the agent's "updates available" belongs: the unfiltered updates list.
    public static let pendingUpdatesDestination: SidebarSelection = .updates(.all)
}
